import Foundation
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

class AudioStreamCoordinator: NSObject, ObservableObject {
    private var audioManager: AudioManager?
    private var websocket: URLSessionWebSocketTask?
    private var session: URLSession
    private var apiKey: String
    private var isRecording = false
    
    private let systemMessage = "You are a helpful and bubbly AI assistant who loves to chat about anything the user is interested about and is prepared to offer them facts."
    
    override init() {
        let apiKey = Env.getValue(forKey: "OPENAI_API_KEY")!
        self.apiKey = apiKey
        self.session = URLSession(configuration: .default)
        
        super.init()
        
        // Initialize audio manager after super.init
        self.audioManager = AudioManager { [weak self] samples in
            self?.processAudioSamples(samples)
        }
        
        setupWebSocket()
    }
    
    private func processAudioSamples(_ samples: [Int16]) {
        guard isRecording, let websocket = websocket else { return }
        
        // Convert samples to Data
        let audioData = Data(bytes: samples, count: samples.count * 2) // 2 bytes per Int16
        
        // Convert to base64
        let base64Audio = audioData.base64EncodedString()
        
        // Prepare audio append message
        let audioAppend: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ]
        
        // Print the first 40 characters of the base64 audio
        print("Sent \(base64Audio.prefix(40))...")
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: audioAppend),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        
        let message = URLSessionWebSocketTask.Message.string(jsonString)
        websocket.send(message) { error in
            if let error = error {
                print("Failed to send audio data: \(error)")
            }
        }
    }
    
    private func playAudioData(_ audioData: Data) {
        // Convert base64 audio data back to Int16 samples
        let samples: [Int16] = audioData.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Int16.self))
        }
        
        // Play the audio using AudioManager
        try? audioManager?.play(buffers: [samples])
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
                // print the first 40 letters of delta
                print("Received \(delta.prefix(40))...")
                // play the audio data
                playAudioData(audioData)
            }
        case "session.updated":
            print("Session updated successfully")
            startRecording()
        default:
            print("Received message of type: \(type)")
        }
    }
    
    // Public methods
    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        try? audioManager?.startRecording()
    }
    
    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        audioManager?.stopRecording()
    }
    
    func disconnect() {
        websocket?.cancel()
        audioManager?.stopRecording()
        audioManager?.stopPlayback()
    }
}
