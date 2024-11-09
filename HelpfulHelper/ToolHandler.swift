import Foundation
import UIKit

class ToolHandler {
    private let cameraCoordinator: CameraSessionCoordinator
    
    init(cameraCoordinator: CameraSessionCoordinator) {
        self.cameraCoordinator = cameraCoordinator
    }
    
    var toolDefinitions: [[String: Any]] {
        return [
//            [
//                "type": "function",
//                "name": "observe",
//                "description": """
//                Allows the AI to visually perceive its surroundings using the mounted camera.
//                The AI can use this to gather information about the environment, recognize people or objects,
//                and provide more contextual responses. The observation is private to the AI,
//                so it must describe what it sees to the user if asked about the environment.
//                """,
//                "parameters": [
//                    "type": "object",
//                    "properties": [
//                        "query": [
//                            "description": """
//                            The specific aspect or question about the environment that the AI wants to observe.
//                            This can range from general scene description to specific object or person identification.
//                            """,
//                            "type": "string"
//                        ],
//                        "camera": [
//                            "description": """
//                            The camera direction to use for observation, either 'front' or 'back'.
//                            Use 'front' for self-view or when interacting directly with users,
//                            and 'back' for observing the broader environment.
//                            """,
//                            "type": "string"
//                        ]
//                    ],
//                    "required": ["query", "camera"]
//                ]
//            ],
            [
                "type": "function",
                "name": "webSearch",
                "description": "Performs a web search using the Bing Search API and returns the results.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "description": "The search query to be used.",
                            "type": "string"
                        ]
                    ],
                    "required": ["query"]
                ]
            ],
            [
                "type": "function",
                "name": "associateLastFaceWithUser",
                "description": "Associates the last detected face with a users's name.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "userName": [
                            "type": "string",
                            "description": "The name of the user to associate with the face of the user."
                        ]
                    ],
                    "required": ["userName"]
                ]
            ]
        ]
    }
    
    func handleFunctionCall(name: String, callId: String, arguments: String) async throws -> [String: Any] {
        guard let argsData = arguments.data(using: .utf8),
              let argsJson = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] else {
            throw ToolHandlerError.invalidFunctionCall
        }
        
        switch name {
        case "observe":
            return try await handleObserve(callId: callId, arguments: argsJson)
        case "webSearch":
            return try await handleWebSearch(callId: callId, arguments: argsJson)
        case "associateLastFaceWithUser":
            return try await handleAssociateLastFaceWithUser(callId: callId, arguments: argsJson)
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
        
    private func handleWebSearch(callId: String, arguments: [String: Any]) async throws -> [String: Any] {
        guard let query = arguments["query"] as? String else {
            throw ToolHandlerError.invalidArguments
        }
        
        let searchResults = try await performWebSearch(query: query)
        
        return [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": searchResults
            ]
        ]
    }
    
    private func performWebSearch(query: String) async throws -> String {
        let apiKey = Env.getValue(forKey: "BING_API_KEY")!
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://api.bing.microsoft.com/v7.0/search?q=\(encodedQuery)"
        
        guard let url = URL(string: urlString) else {
            throw ToolHandlerError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        
        guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let webPages = json["webPages"] as? [String: Any],
              let value = webPages["value"] as? [[String: Any]] else {
            throw ToolHandlerError.invalidResponse
        }
        
        let results = value.map { result -> [String: String] in
            return [
                "name": result["name"] as? String ?? "",
                "url": result["url"] as? String ?? "",
                "date": result["datePublishedDisplayText"] as? String ?? "",
                "snippet": result["snippet"] as? String ?? ""
            ]
        }
        
        return try JSONSerialization.data(withJSONObject: results).toString()
    }
    private func handleAssociateLastFaceWithUser(callId: String, arguments: [String: Any]) async throws -> [String: Any] {
        guard let userName = arguments["userName"] as? String else {
            throw ToolHandlerError.invalidArguments
        }
        
        let success = DBHelper.shared.associateLastEmbeddingWithUser(userName: userName)
        
        let resultMessage = success ? "Successfully associated the last face with user: \(userName)" : "Failed to associate the last face with user: \(userName)"
        
        return [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": resultMessage
            ]
        ]
    }
}

enum ToolHandlerError: Error {
    case invalidFunctionCall
    case unknownFunction
    case invalidArguments
    case invalidResponse
    case missingContent
    case invalidURL
}

extension Data {
    func toString() throws -> String {
        guard let str = String(data: self, encoding: .utf8) else {
            throw ToolHandlerError.invalidResponse
        }
        return str
    }
}

func callAnthropicAPI(imageData: Data, query: String) async throws -> String {
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
        //"model": "claude-3-5-sonnet-latest",
        "model": "claude-3-haiku-20240307",
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
    
    guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
        throw ToolHandlerError.invalidResponse
    }
    
    guard let content = json["content"] as? [[String: Any]],
            let firstContent = content.first,
            let text = firstContent["text"] as? String else {
        throw ToolHandlerError.missingContent
    }
    
    return text
}
