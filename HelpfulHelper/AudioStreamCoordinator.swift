import Foundation
import AVFoundation
import WebKit

struct Env {
    static func getValue(forKey key: String) -> String? {
        guard let path = Bundle.main.path(forResource: ".env", ofType: nil) else {
            print("No .env file found")
            return nil
        }
        
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            
            for line in lines {
                let parts = line.components(separatedBy: "=")
                if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces) == key {
                    return parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
            
            print("Key \(key) not found in .env file")
            return nil
        } catch {
            print("Error reading .env file: \(error)")
            return nil
        }
    }
}

extension AVAudioFormat {
    func debugDescription() -> String {
        return """
        Format:
          - Sample Rate: \(sampleRate)
          - Channel Count: \(channelCount)
          - Common Format: \(commonFormat.rawValue)
          - Stream Description: \(streamDescription.pointee)
        """
    }
}

class AudioStreamCoordinator: NSObject, AVAudioRecorderDelegate, ObservableObject {
    private var audioEngine: AVAudioEngine
    private var inputNode: AVAudioInputNode
    private var playerNode: AVAudioPlayerNode
    private var websocket: URLSessionWebSocketTask?
    private var session: URLSession
    private var apiKey: String
    private var isRecording = false
    
    // Remove the fixed engine format and make it dynamic based on hardware
    private var engineFormat: AVAudioFormat?
    
    // Format for OpenAI API (24kHz)
    private let apiFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24000,
        channels: 1,
        interleaved: false
    )!  // Force unwrap since this is a known good format
    
    private let hardwareFormat = AVAudioFormat(
            standardFormatWithSampleRate: 48000,
            channels: 1
        )!
    
    private var inputConverter: AVAudioConverter?
    private var outputConverter: AVAudioConverter?
    
    private let systemMessage = "You are a helpful and bubbly AI assistant who loves to chat about anything the user is interested about and is prepared to offer them facts."
    
    override init() {
        let apiKey = Env.getValue(forKey: "OPENAI_API_KEY")!
                
        self.apiKey = apiKey
        self.audioEngine = AVAudioEngine()
        self.inputNode = audioEngine.inputNode
        self.playerNode = AVAudioPlayerNode()
        self.session = URLSession(configuration: .default)
        
        super.init()
        
        setupAudioSession()
        setupAudioEngine()
        setupConverters()
        setupWebSocket()
    }
    
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    private func setupConverters() {
        // Store the engine format
        self.engineFormat = hardwareFormat
        
        // Create converters using the hardware format
        inputConverter = AVAudioConverter(from: hardwareFormat, to: apiFormat)
        outputConverter = AVAudioConverter(from: apiFormat, to: hardwareFormat)
    }
    
    private func setupAudioEngine() {
        // Setup player node
        audioEngine.attach(playerNode)
        
        print(hardwareFormat)
        print(apiFormat)

        // Connect player to output using hardware format
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: hardwareFormat)
        
        // Prepare and start engine
        audioEngine.prepare()
        do {
            try audioEngine.start()
            print("Audio engine started")
            print(inputNode.inputFormat(forBus: 0))

            // Setup input tap with hardware format
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, time in
                print("Got audio buffer")
                self?.processAudioBuffer(buffer)
            }
            
        } catch {
            print("Failed to start audio engine: \(error)")
        }
    }
    
    private func convertBufferToAPI(_ sourceBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter = inputConverter,
              let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: apiFormat,
                frameCapacity: AVAudioFrameCount(Double(sourceBuffer.frameLength) * 24000 / Double(sourceBuffer.format.sampleRate))
              ) else {
            print("Failed to create conversion buffer")
            return nil
        }
        
        var error: NSError?
        converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        
        if let error = error {
            print("Conversion error: \(error)")
            return nil
        }
        
        return convertedBuffer
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRecording,
              let convertedBuffer = convertBufferToAPI(buffer),
              let websocket = websocket else { return }
        
        // Get the audio data from the converted buffer
        let frameCount = Int(convertedBuffer.frameLength)
        let channelCount = Int(convertedBuffer.format.channelCount)
        let channelData = convertedBuffer.int16ChannelData?[0]
        
        guard let data = channelData else { return }
        let audioData = Data(bytes: data, count: frameCount * channelCount * 4)
        
        // Convert to base64
        let base64Audio = audioData.base64EncodedString()
        
        // Prepare audio append message
        let audioAppend: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: audioAppend),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        
        print("Sending audio data")
        print(jsonString)
        
        let message = URLSessionWebSocketTask.Message.string(jsonString)
        websocket.send(message) { error in
            if let error = error {
                print("Failed to send audio data: \(error)")
            }
        }
    }
    
    private func convertBufferFromAPI(_ data: Data) -> AVAudioPCMBuffer? {
        guard let engineFormat = engineFormat,
              let converter = outputConverter else { return nil }
        
        // Create source buffer with API format
        let frameCount = data.count / 4  // 4 bytes per float
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: apiFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return nil }
        
        sourceBuffer.frameLength = sourceBuffer.frameCapacity
        
        // Copy data to source buffer
        data.withUnsafeBytes { rawBufferPointer in
            guard let sourcePtr = rawBufferPointer.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            sourceBuffer.floatChannelData?[0].update(from: sourcePtr, count: frameCount)
        }
        
        // Create destination buffer with engine format
        let destFrameCapacity = AVAudioFrameCount(Double(frameCount) * engineFormat.sampleRate / 24000)
        guard let destBuffer = AVAudioPCMBuffer(
            pcmFormat: engineFormat,
            frameCapacity: destFrameCapacity
        ) else { return nil }
        
        // Convert to engine format
        var error: NSError?
        converter.convert(to: destBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        
        if let error = error {
            print("Conversion error: \(error)")
            return nil
        }
        
        return destBuffer
    }
    
    private func playAudioData(_ audioData: Data) {
        guard let buffer = convertBufferFromAPI(audioData) else {
            print("Failed to convert received audio data")
            return
        }
        print("Received audio data: \(audioData.count) bytes")
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
        playerNode.play()
    }
    
    private func setupWebSocket() {
        guard var urlComponents = URLComponents(string: "wss://api.openai.com/v1/realtime") else { return }
        urlComponents.queryItems = [URLQueryItem(name: "model", value: "gpt-4o-realtime-preview-2024-10-01")]
        
        guard let url = urlComponents.url else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        
        websocket = session.webSocketTask(with: request)
        websocket?.resume()
        
        // Send initial session configuration
        sendSessionConfiguration()
        receiveWebSocketMessages()
    }
    
    private func sendSessionConfiguration() {
        let config: [String: Any] = [
            "type": "session.update",
            "session": [
                "turn_detection": ["type": "server_vad"],
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "voice": "shimmer",
                "instructions": systemMessage,
                "modalities": ["text", "audio"]
            ]
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: config),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        
        let message = URLSessionWebSocketTask.Message.string(jsonString)
        websocket?.send(message) { error in
            if let error = error {
                print("Failed to send session configuration: \(error)")
            }
        }
    }
    
    private func receiveWebSocketMessages() {
        websocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.handleWebSocketMessage(text)
                case .data(let data):
                    print("Received binary message: \(data)")
                @unknown default:
                    break
                }
                // Continue receiving messages
                self?.receiveWebSocketMessages()
                
            case .failure(let error):
                print("WebSocket receive error: \(error)")
            }
        }
    }
    
    private func handleWebSocketMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        
        switch type {
        case "response.audio.delta":
            if let delta = json["delta"] as? String,
               let audioData = Data(base64Encoded: delta) {
                print("Received audio delta")
                playAudioData(audioData)
            }
        case "session.updated":
            print("Session updated successfully")
            startRecording()
        default:
            print("Received message of type: \(type)")
            print("JSON: \(json)")
        }
    }
    
    // Public methods
    func startRecording() {
        isRecording = true
    }
    
    func stopRecording() {
        isRecording = false
    }
    
    func disconnect() {
        websocket?.cancel()
        audioEngine.stop()
        inputNode.removeTap(onBus: 0)
    }
}
