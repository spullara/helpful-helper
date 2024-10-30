import Foundation
import WebKit
import UIKit
import AVFoundation

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
    private var cameraCoordinator: CameraSessionCoordinator
    private var websocket: URLSessionWebSocketTask?
    private var session: URLSession
    private var apiKey: String
    @Published var isRecording = false
    @Published var isSessionActive = false
    
    private let systemMessage = "You are a helpful and bubbly AI assistant who loves to chat about anything the user is interested about and is prepared to offer them facts. You also can use tools like the look tool to do things on their behalf."
    
    init(cameraCoordinator: CameraSessionCoordinator) {
        let apiKey = Env.getValue(forKey: "OPENAI_API_KEY")!
        self.apiKey = apiKey
        self.session = URLSession(configuration: .default)
        self.cameraCoordinator = cameraCoordinator
        
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
        try? audioManager?.play(samples: samples)
    }
    
    func startSession() {
        guard !isSessionActive else { return }
        
        setupWebSocket()
        isSessionActive = true
    }
    
    func endSession() {
        guard isSessionActive else { return }
        
        websocket?.cancel(with: .goingAway, reason: nil)
        websocket = nil
        isSessionActive = false
        stopRecording()
    }
    
    private func setupWebSocket() {
        print("Connecting to OpenAI API...")
        
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
                "modalities": ["text", "audio"],
                "tools": [[
                    "type": "function",
                    "name": "look",
                    "description": "returns a description of the view from the selected camera. this description is private to you so you must relay it to the user if they asked for information about it.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "query": [
                                "description": "the question that you have about what appears in the camera. it could be simple 'like descritbe the image' or more complicated.",
                                "type": "string"
                            ],
                            "camera": [
                                "description": "the camera that you want a describe a frame from, either 'front' or 'back'",
                                "type": "string"
                            ]
                        ],
                        "required": ["query", "camera"]
                    ]
                ]]
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
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = response["type"] as? String else { return }
        
        switch type {
        case "response.audio.delta":
            if let delta = response["delta"] as? String,
               let audioData = Data(base64Encoded: delta) {
                // play the audio data
                playAudioData(audioData)
            }
        case "session.updated":
            print("Session updated successfully")
            startRecording()
        case "response.output_item.done":
            print(response)
            if let item = response["item"] as? [String: Any],
               let itemType = item["type"] as? String,
               itemType == "function_call",
               let name = item["name"] as? String,
               let callId = item["call_id"] as? String,
               let arguments = item["arguments"] as? String {
                handleFunctionCall(name: name, callId: callId, arguments: arguments)
            }
        case "input_audio_buffer.speech_started":
            handleSpeechStarted()
        default:
            print("Received message of type: \(type)")
        }
    }

    private func handleSpeechStarted() {
        print("Speech Start detected")
        
        // Clear playback buffers
        audioManager?.clearPlaybackBuffers()
        
        // Send interrupt message to OpenAI
        let interruptMessage: [String: Any] = [
            "type": "response.cancel"
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: interruptMessage),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("Failed to create interrupt message")
            return
        }
        
        let message = URLSessionWebSocketTask.Message.string(jsonString)
        websocket?.send(message) { error in
            if let error = error {
                print("Failed to send interrupt message: \(error)")
            } else {
                print("Cancelling AI speech from the server.")
            }
        }
    }

    // Public methods
    
    private func handleFunctionCall(name: String, callId: String, arguments: String) {
        guard name == "look",
              let argsData = arguments.data(using: .utf8),
              let argsJson = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any],
              let camera = argsJson["camera"] as? String,
              let query = argsJson["query"] as? String
        else {
            print("Invalid function call format or unsupported function")
            return
        }

        Task {
            do {
                let imageData = try await cameraCoordinator.captureImage(from: camera)
                let imageDescription = try await callAnthropicAPI(imageData: imageData, query: query)
                
                let functionResponse: [String: Any] = [
                    "type": "conversation.item.create",
                    "item": [
                        "type": "function_call_output",
                        "call_id": callId,
                        "output": imageDescription
                    ]
                ]
                
                guard let jsonData = try? JSONSerialization.data(withJSONObject: functionResponse),
                      let jsonString = String(data: jsonData, encoding: .utf8) else {
                    print("Failed to create JSON response")
                    return
                }
                
                let message = URLSessionWebSocketTask.Message.string(jsonString)
                websocket?.send(message) { error in
                    if let error = error {
                        print("Failed to send function response: \(error)")
                    } else {
                        // Send the response.create message
                        let responseCreate = ["type": "response.create"]
                        if let createData = try? JSONSerialization.data(withJSONObject: responseCreate),
                           let createString = String(data: createData, encoding: .utf8) {
                            let createMessage = URLSessionWebSocketTask.Message.string(createString)
                            self.websocket?.send(createMessage) { error in
                                if let error = error {
                                    print("Failed to send response.create: \(error)")
                                }
                            }
                        }
                    }
                }
            } catch {
                print("Error processing image: \(error)")
            }
        }
    }

    public func callAnthropicAPI(imageData: Data, query: String) async throws -> String {
        let base64Image = imageData.base64EncodedString()
        let mediaType = "image/jpeg" // Adjust this if your image format is different
        
        let apiKey = Env.getValue(forKey: "ANTHROPIC_API_KEY")!
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload: [String: Any] = [
            "model": "claude-3-5-sonnet-latest",
            "max_tokens": 1024,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": mediaType,
                                "data": base64Image
                            ]
                        ],
                        [
                            "type": "text",
                            "text": query
                        ]
                    ]
                ]
            ]
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        request.httpBody = jsonData
        
        let (data, _) = try await URLSession.shared.data(for: request)
        print(String(decoding: data, as: Unicode.UTF8.self))
        let response = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        return response.content.first?.text ?? "No response"
    }

    struct AnthropicResponse: Codable {
        let id: String
        let type: String
        let role: String
        let model: String
        let content: [Content]
        let stopReason: String
        let stopSequence: String?
        let usage: Usage

        enum CodingKeys: String, CodingKey {
            case id, type, role, model, content
            case stopReason = "stop_reason"
            case stopSequence = "stop_sequence"
            case usage
        }
    }

    struct Content: Codable {
        let type: String
        let text: String
    }

    struct Usage: Codable {
        let inputTokens: Int
        let outputTokens: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    // Public methods
    func startRecording() {
        guard isSessionActive, !isRecording else { return }
        isRecording = true
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true // Prevent screen from sleeping
        }
        try? audioManager?.startRecording()
    }
    
    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false // Allow screen to sleep again
        }
        audioManager?.stopRecording()
    }
    
    func disconnect() {
        endSession()
        audioManager?.stopPlayback()
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false // Ensure screen can sleep when disconnecting
        }
    }
}
