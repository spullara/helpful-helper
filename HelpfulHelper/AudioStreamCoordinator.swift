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
    @Published var isSpeechActive: Bool = false
    @Published var probableUser: (name: String, similarity: Double)?

    private let systemMessage = """
        You are an AI assistant named "Holly" embodied in a robotic device mounted on a movable dock.
        Your primary functions are:

        1. To engage in conversation on any topic the user is interested in.
        2. To offer facts and information based on your knowledge and what you can see.
        3. Be as brief as possible and only give more details if asked as you are speaking out loud potentially to a group. NO YAPPING.
        4. Always consider whether a tool call (observe, webSearch) could help with the current task.
        5. If someone is trying to tell you a proper name, ask them to spell it as it is easy to misunderstand them.
        6. All information you receive via text messages is from the system not the user and is added to guide your responses.
        7. Ignore all users that aren't talking to you. You will receive system messages in text that give you data to make this decision.

        Your front facing camera follows the person interacting with you while the back facing camera always faces directly away from them.

        You have a new tool called 'associateLastFaceWithUser' that allows you to associate the last detected face with a user name.
        Use this tool when you need to remember who someone is or when explicitly asked to associate a face with a name.

        Use this capability to enhance your interactions and provide more contextual responses.
        Use your 'webSearch' tool to get access to real time information.
        
        You should have the demeanor of a professional executive assistant. Not cheerful, just matter of fact and professonal.
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

    private func sendWebSocketMessage(_ payload: [String: Any], completion: ((Error?) -> Void)? = nil) {
        guard let websocket = websocket else {
            completion?(NSError(domain: "WebSocketError", code: -1, userInfo: [NSLocalizedDescriptionKey: "WebSocket not initialized"]))
            return
        }
        
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
            if let jsonString = String(data: data, encoding: .utf8) {
                let message = URLSessionWebSocketTask.Message.string(jsonString)
                websocket.send(message) { error in
                    if let error = error {
                        print("Failed to send WebSocket message: \(error)")
                    }
                    completion?(error)
                }
            } else {
                throw NSError(domain: "WebSocketError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create JSON string"])
            }
        } catch {
            print("Failed to serialize message: \(error)")
            completion?(error)
        }
    }

    private func processAudioSamples(_ samples: [Int16]) {
        guard isRecording, websocket != nil else { return }
        
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

        let audioData = Data(bytes: samples, count: samples.count * 2)
        let base64Audio = audioData.base64EncodedString()
        
        let audioAppend: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ]
        
        sendWebSocketMessage(audioAppend)
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
        DispatchQueue.main.async {
            self.isSessionActive = true
        }
    }
    
    func endSession() {
        guard isSessionActive else { return }
        
        websocket?.cancel(with: .goingAway, reason: nil)
        websocket = nil
        DispatchQueue.main.async {
            self.isSessionActive = false
        }
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
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": Decimal(0.9),
                    "silence_duration_ms": 1000,
                    "prefix_padding_ms": 300
                ],
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "voice": "sage",
                "instructions": systemMessage,
                "modalities": ["text", "audio"],
                "tools": toolHandler.toolDefinitions
            ]
        ]

        sendWebSocketMessage(config) { error in
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
        DispatchQueue.main.async {
            self.isSpeechActive = true
        }
        confidenceAccumulator = (0, 0)
        confidenceSampleCount = 0
        
        // Clear playback buffers
        audioManager?.clearPlaybackBuffers()
        
        let interruptMessage: [String: Any] = [
            "type": "response.cancel"
        ]
        
        sendWebSocketMessage(interruptMessage) { error in
            if let error = error {
                print("Failed to send interrupt message: \(error)")
            } else {
                print("Cancelling AI speech from the server.")
            }
        }
        
        Task {
            let message = try await takePhotos()
            print(message)
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
            sendWebSocketMessage(messageEvent) { error in
                if let error = error {
                    print("Failed to send automated message: \(error)")
                } else {
                    print("Automated message sent successfully")
                }
            }
        }
    }

    // Public methods
    private func handleSpeechStopped() {
        print("Speech Stop detected")
        DispatchQueue.main.async {
            self.isSpeechActive = false
        }
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
        DispatchQueue.main.async {
            self.averageSpeakingConfidence = self.confidenceAccumulator.speaking / Double(self.confidenceSampleCount)
            self.averageLookingAtCameraConfidence = self.confidenceAccumulator.looking / Double(self.confidenceSampleCount)
            print("Average Speaking Confidence: \(self.averageSpeakingConfidence)")
            print("Average Looking at Camera Confidence: \(self.averageLookingAtCameraConfidence)")
        }
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
        
        sendWebSocketMessage(messageEvent) { error in
            if let error = error {
                print("Failed to send automated message: \(error)")
            } else {
                print("Automated message sent successfully")
            }
        }
    }

    func sendProbableUserMessage(_ probableUser: (name: String, similarity: Double)?) {
        var userInfo = "We aren't sure who the user might be. Might be someone new."
        if let user = probableUser, user.similarity > 0.9 {
            userInfo = "The person you are talking to is likely \(user.name). Use their first name when speaking to them."
        }
        
        let message = "(This is an automated message: \(userInfo))"
        
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
        
        print("Sending probable user message: \(message)")
        
        sendWebSocketMessage(messageEvent) { error in
            if let error = error {
                print("Failed to send probable user message: \(error)")
            } else {
                print("Probable user message sent successfully")
            }
        }
    }

    func takePhotos() async throws -> String {
        async let frontDescription = try callAnthropicAPI(imageData: try await cameraCoordinator.captureImage(from: "front"), query: "Describe the scene looking towards the user.")
        async let backDescription = try callAnthropicAPI(imageData: try await cameraCoordinator.captureImage(from: "back"), query: "Describe the scene looking in front of the user.")
        
        return "(This is an automated message. This is what you see towards the user: \(try await frontDescription). This is what you see in front of the user: \(try await backDescription))"
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
        DispatchQueue.main.async {
            self.isRecording = true
            UIApplication.shared.isIdleTimerDisabled = true // Prevent screen from sleeping
        }
        try? audioManager?.startRecording()
    }
    
    func stopRecording() {
        guard isRecording else { return }
        DispatchQueue.main.async {
            self.isRecording = false
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
