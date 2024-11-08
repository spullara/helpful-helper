import Foundation

class GoogleAIImageHandler {
    private let apiKey: String
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta"
    private let uploadURL = "https://storage.googleapis.com/upload/v1beta/files"
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    func processImage(_ imageData: Data, withPrompt prompt: String) async throws -> String {
        let fileURI = try await uploadImage(imageData)
        return try await generateContent(fileURI: fileURI, prompt: prompt)
    }
    
    private func uploadImage(_ imageData: Data) async throws -> String {
        let mimeType = "image/jpeg" // Adjust if needed
        let displayName = "IMAGE"
        let numBytes = imageData.count
        
        // Step 1: Initial resumable request
        let uploadURL = try await getUploadURL(numBytes: numBytes, mimeType: mimeType, displayName: displayName)
        
        // Step 2: Upload the actual bytes
        let fileInfo = try await uploadBytes(to: uploadURL, data: imageData, numBytes: numBytes)
        
        guard let file = fileInfo["file"] as? [String: Any],
              let fileURI = file["uri"] as? String else {
            throw GoogleAIError.invalidResponse("File URI not found in response")
        }
        
        return fileURI
    }
    
    private func getUploadURL(numBytes: Int, mimeType: String, displayName: String) async throws -> URL {
        var request = URLRequest(url: URL(string: "\(uploadURL)?key=\(apiKey)")!)
        request.httpMethod = "POST"
        request.addValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        request.addValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        request.addValue("\(numBytes)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        request.addValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = ["file": ["display_name": displayName]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              let uploadURL = httpResponse.value(forHTTPHeaderField: "X-Goog-Upload-URL") else {
            throw GoogleAIError.invalidResponse("Upload URL not found in response headers")
        }
        
        return URL(string: uploadURL)!
    }
    
    private func uploadBytes(to url: URL, data: Data, numBytes: Int) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("\(numBytes)", forHTTPHeaderField: "Content-Length")
        request.addValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        request.addValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        request.httpBody = data
        
        let (responseData, _) = try await URLSession.shared.data(for: request)
        guard let fileInfo = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw GoogleAIError.invalidResponse("Invalid JSON response")
        }
        
        return fileInfo
    }
    
    private func generateContent(fileURI: String, prompt: String) async throws -> String {
        let url = URL(string: "\(baseURL)/models/gemini-1.5-flash:generateContent?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt],
                        ["file_data": ["mime_type": "image/jpeg", "file_uri": fileURI]]
                    ]
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (responseData, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw GoogleAIError.invalidResponse("Unable to parse response")
        }
        
        return text
    }
}

enum GoogleAIError: Error {
    case invalidResponse(String)
}