//
//  AudioStreamCoordinator.swift
//  HelpfulHelper
//
//  Created by Sam Pullara on 10/24/24.
//


import Foundation
import AVFoundation
import WebKit

struct Environment {
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

class AudioStreamCoordinator: NSObject, AVAudioRecorderDelegate {
    private var audioEngine: AVAudioEngine
    private var inputNode: AVAudioInputNode
    private var playerNode: AVAudioPlayerNode
    private var websocket: URLSessionWebSocketTask?
    private var session: URLSession
    private var isRecording = false
    private let apiKey: String
    
    // Audio format settings for 24kHz PCM
    private let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24000,
        channels: 1,
        interleaved: true
    )
    
    private let systemMessage = "You are a helpful and bubbly AI assistant who loves to chat about anything the user is interested about and is prepared to offer them facts."
    
    override init() {
        let apiKey = Environment.getValue(forKey: "OPENAI_API_KEY")!
                
        self.apiKey = apiKey
        self.audioEngine = AVAudioEngine()
        self.inputNode = audioEngine.inputNode
        self.playerNode = AVAudioPlayerNode()
        self.session = URLSession(configuration: .default)
        
        super.init()
        
        setupAudioSession()
        setupAudioEngine()
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
    
    private func setupAudioEngine() {
        // Setup player node
        audioEngine.attach(playerNode)
        
        // Connect player to output
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: audioFormat)
        
        // Setup input tap
        inputNode.installTap(onBus: 0, bufferSize: 8192, format: audioFormat) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer)
        }
        
        // Prepare and start engine
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("Failed to start audio engine: \(error)")
        }
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
                "input_audio_format": "g711_ulaw",
                "output_audio_format": "g711_ulaw",
                "voice": "alloy",
                "instructions": systemMessage,
                "modalities": ["text", "audio"],
                "temperature": 0.8
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
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRecording,
              let channelData = buffer.int16ChannelData?[0],
              let websocket = websocket else { return }
        
        // Convert to Data
        let bufferData = Data(bytes: channelData, count: Int(buffer.frameLength) * 2)
        
        // Convert to base64
        let base64Audio = bufferData.base64EncodedString()
        
        // Prepare audio append message
        let audioAppend: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: audioAppend),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        
        let message = URLSessionWebSocketTask.Message.string(jsonString)
        websocket.send(message) { error in
            if let error = error {
                print("Failed to send audio data: \(error)")
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
                playAudioData(audioData)
            }
        case "session.updated":
            print("Session updated successfully")
        default:
            print("Received message of type: \(type)")
        }
    }
    
    private func playAudioData(_ audioData: Data) {
        // Convert audio data to buffer
        let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat!, frameCapacity: UInt32(audioData.count))
        audioData.withUnsafeBytes { ptr in
            guard let samples = audioBuffer?.int16ChannelData?[0] else { return }
            samples.assign(from: ptr.baseAddress!, count: audioData.count)
            audioBuffer?.frameLength = UInt32(audioData.count)
        }
        
        // Play the buffer
        if let buffer = audioBuffer {
            playerNode.scheduleBuffer(buffer, completionHandler: nil)
            playerNode.play()
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
