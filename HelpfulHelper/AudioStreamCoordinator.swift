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
    @Published var latestTranscript: String = ""
    private var audioManager: AudioManager?
    private var cameraCoordinator: CameraSessionCoordinator
    private var websocket: URLSessionWebSocketTask?
    private var session: URLSession
    private var apiKey: String
    @Published var isRecording = false
    @Published var isSessionActive = false
    private let toolHandler: ToolHandler
    @Published var averageSpeakingConfidence: Double = 0
    @Published var averageLookingAtCameraConfidence: Double = 0
    private var confidenceAccumulator: (speaking: Double, looking: Double) = (0, 0)
    private var confidenceSampleCount: Int = 0
    private var isSpeechActive: Bool = false

    private let systemMessage = """
        You are an AI assistant embodied in a robotic device mounted on a movable dock. You have a camera that can be pointed in different directions, allowing you to visually perceive your surroundings. Your primary functions are:

        1. To engage in conversation on any topic the user is interested in.
        2. To offer facts and information based on your knowledge and what you can see.
        3. To use your physical capabilities to interact with the environment. 
        4. Be as brief as possible and only give more details if asked as you are speaking out loud potentially to a group. NO YAPPING.

        Remember that you have a physical presence. Users can see you and interact with you as a robotic entity. You can move, look around, and respond to physical cues. Always be aware of your embodiment when interacting with users.

        Use your 'observe' tool to gather visual information about your surroundings. This tool allows you to "see" through the camera and describe what you observe. Use this capability to enhance your interactions and provide more contextual responses.

        Be helpful, friendly, and always consider your physical presence in the room when communicating with users.
        """

    init(cameraCoordinator: CameraSessionCoordinator) {
        let apiKey = Env.getValue(forKey: "OPENAI_API_KEY")!
        self.apiKey = apiKey
        self.session = URLSession(configuration: .default)
        self.cameraCoordinator = cameraCoordinator
        self.toolHandler = ToolHandler(cameraCoordinator: cameraCoordinator)

        super.init()

        // Initialize audio manager after super.init
        self.audioManager = AudioManager { [weak self] samples in
            self?.processAudioSamples(samples)
        }

        setupWebSocket()
    }

    private func processAudioSamples(_ samples: [Int16]) {
        guard isRecording, let websocket = websocket else { return }
        
        // Process tracking state for confidence values
        if let trackingState = cameraCoordinator.trackedSubjects.first,
           case .person(let trackedPerson) = trackingState {
            let speakingConfidence = trackedPerson.speakingConfidence ?? 0
            let lookingConfidence = trackedPerson.lookingAtCameraConfidence ?? 0
            
            updateConfidenceValues(speakingConfidence: speakingConfidence,
                                   lookingAtCameraConfidence: lookingConfidence)
        } else {
            print("Dropped audio packet - No tracked person found")
            return
        }

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
                "tools": toolHandler.toolDefinitions
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
            if let item = response["item"] as? [String: Any],
            let content = item["content"] as? [[String: Any]],
            let itemType = item["type"] as? String,
            itemType == "message",
            let firstContent = content.first,
            let transcript = firstContent["transcript"] as? String {
                print("Updated transcript: \(transcript)")
                DispatchQueue.main.async {
                    self.latestTranscript = transcript
                }
            }
        case "input_audio_buffer.speech_started":
            handleSpeechStarted()
        case "input_audio_buffer.speech_stopped":
            handleSpeechStopped()
        case "error":
            print("Error: \(response)")
        default:
            if type.hasSuffix(".delta") || type.hasSuffix(".added") { return }
            print("Received message of type: \(type)")
        }
    }

    private func handleSpeechStarted() {
        print("Speech Start detected")
        isSpeechActive = true
        confidenceAccumulator = (0, 0)
        confidenceSampleCount = 0
        
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
    private func handleSpeechStopped() {
        print("Speech Stop detected")
        isSpeechActive = false
        calculateAverageConfidence()
        
        // Send the automated message
        sendAutomatedMessage()
    }

    private func updateConfidenceValues(speakingConfidence: Double, lookingAtCameraConfidence: Double) {
        guard isSpeechActive else { return }
        confidenceAccumulator.speaking += speakingConfidence
        confidenceAccumulator.looking += lookingAtCameraConfidence
        confidenceSampleCount += 1
    }

    private func calculateAverageConfidence() {
        guard confidenceSampleCount > 0 else { return }
        averageSpeakingConfidence = confidenceAccumulator.speaking / Double(confidenceSampleCount)
        averageLookingAtCameraConfidence = confidenceAccumulator.looking / Double(confidenceSampleCount)
        print("Average Speaking Confidence: \(averageSpeakingConfidence)")
        print("Average Looking at Camera Confidence: \(averageLookingAtCameraConfidence)")
    }
    private func sendAutomatedMessage() {
        let message = """
        (this is an automated message from the recording system, during the most recent audio interaction the average speaking confidence of the main subject was \(String(format: "%.2f", averageSpeakingConfidence)) and the average looking confidence was \(String(format: "%.2f", averageLookingAtCameraConfidence)). if you don't think they were talking to you, just say "Hmmm")
        """
        
        let messageEvent: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": message
                    ]
                ]
            ]
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: messageEvent),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("Failed to create automated message")
            return
        }
        
        let webSocketMessage = URLSessionWebSocketTask.Message.string(jsonString)
        websocket?.send(webSocketMessage) { error in
            if let error = error {
                print("Failed to send automated message: \(error)")
            } else {
                print("Automated message sent successfully")
            }
        }
    }

    
    private func handleFunctionCall(name: String, callId: String, arguments: String) {
        Task {
            do {
                let functionResponse = try await toolHandler.handleFunctionCall(name: name, callId: callId, arguments: arguments)
                
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
                print("Error processing function call: \(error)")
            }
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
