import Foundation
import UIKit

class ToolHandler {
    private let cameraCoordinator: CameraSessionCoordinator
    
    init(cameraCoordinator: CameraSessionCoordinator) {
        self.cameraCoordinator = cameraCoordinator
    }
    
    var toolDefinitions: [[String: Any]] {
        return [[
            "type": "function",
            "name": "observe",
            "description": """
            Allows the AI to visually perceive its surroundings using the mounted camera. 
            The AI can use this to gather information about the environment, recognize people or objects, 
            and provide more contextual responses. The observation is private to the AI, 
            so it must describe what it sees to the user if asked about the environment.
            """,
            "parameters": [
                "type": "object",
                "properties": [
                    "query": [
                        "description": """
                        The specific aspect or question about the environment that the AI wants to observe. 
                        This can range from general scene description to specific object or person identification.
                        """,
                        "type": "string"
                    ],
                    "camera": [
                        "description": """
                        The camera direction to use for observation, either 'front' or 'back'. 
                        Use 'front' for self-view or when interacting directly with users, 
                        and 'back' for observing the broader environment.
                        """,
                        "type": "string"
                    ]
                ],
                "required": ["query", "camera"]
            ]
        ]]
    }
    
    func handleFunctionCall(name: String, callId: String, arguments: String) async throws -> [String: Any] {
        guard let argsData = arguments.data(using: .utf8),
              let argsJson = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] else {
            throw ToolHandlerError.invalidFunctionCall
        }
        
        switch name {
        case "observe":
            return try await handleObserve(callId: callId, arguments: argsJson)
        // Add more cases here for future tools
        default:
            throw ToolHandlerError.unknownFunction
        }
    }
    
    private func handleObserve(callId: String, arguments: [String: Any]) async throws -> [String: Any] {
        guard let camera = arguments["camera"] as? String,
              let query = arguments["query"] as? String else {
            throw ToolHandlerError.invalidArguments
        }

        let imageData = try await cameraCoordinator.captureImage(from: camera)
        let imageDescription = try await callAnthropicAPI(imageData: imageData, query: query)
        
        return [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": imageDescription
            ]
        ]
    }
    
    private func callAnthropicAPI(imageData: Data, query: String) async throws -> String {
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
        let response = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        return response.content.first?.text ?? "No response"
    }
}

enum ToolHandlerError: Error {
    case invalidFunctionCall
    case unknownFunction
    case invalidArguments
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