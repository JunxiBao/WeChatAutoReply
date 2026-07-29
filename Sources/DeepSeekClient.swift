import Foundation

// MARK: - DeepSeek API Client

class DeepSeekClient {
    static let shared = DeepSeekClient()
    
    private let baseURL = "https://api.deepseek.com/v1"
    private let session = URLSession.shared
    
    var apiKey: String {
        get { UserDefaults.standard.string(forKey: "deepseek_api_key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "deepseek_api_key") }
    }
    
    var model: String {
        get { UserDefaults.standard.string(forKey: "deepseek_model") ?? "deepseek-chat" }
        set { UserDefaults.standard.set(newValue, forKey: "deepseek_model") }
    }
    
    var systemPrompt: String {
        get {
            UserDefaults.standard.string(forKey: "reply_system_prompt") ??
            "你是一个友好的助手，正在帮用户自动回复微信消息。回复要简洁、自然、有人情味。不要透露你是AI。用中文回复。"
        }
        set { UserDefaults.standard.set(newValue, forKey: "reply_system_prompt") }
    }
    
    /// Per-contact custom system prompts
    var contactPrompts: [String: String] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "contact_prompts"),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            return dict
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "contact_prompts")
            }
        }
    }
    
    /// Get the effective system prompt for a contact
    func effectivePrompt(for contactName: String) -> String {
        return contactPrompts[contactName] ?? systemPrompt
    }
    
    /// Generate a reply for a given message
    func generateReply(
        for message: String,
        contactName: String,
        conversationHistory: [ChatPair] = []
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw DeepSeekError.noAPIKey
        }
        
        var messages: [[String: String]] = [
            ["role": "system", "content": effectivePrompt(for: contactName)]
        ]
        
        // Add conversation history for context
        for pair in conversationHistory.suffix(10) { // Last 10 messages for context
            messages.append(["role": "user", "content": pair.incoming])
            if !pair.outgoing.isEmpty {
                messages.append(["role": "assistant", "content": pair.outgoing])
            }
        }
        
        // Add the current message
        messages.append(["role": "user", "content": "Incoming message from \(contactName): \(message)\n\nGenerate a reply following the system instructions above."])
        
        let requestBody: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": 500,
            "temperature": 0.7,
            "stream": false
        ]
        
        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        request.timeoutInterval = 30
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepSeekError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            if let errorBody = String(data: data, encoding: .utf8) {
                throw DeepSeekError.apiError(statusCode: httpResponse.statusCode, body: errorBody)
            }
            throw DeepSeekError.httpError(statusCode: httpResponse.statusCode)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw DeepSeekError.parseError
        }
        
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Generate a first message to start a conversation
    func generateFirstMessage(contactName: String, recentContext: String) async throws -> String {
        guard !apiKey.isEmpty else { throw DeepSeekError.noAPIKey }
        
        let prompt = """
        你要主动给「\(contactName)」发一条微信消息开启对话。
        
        \(recentContext.isEmpty ? "" : "最近的聊天内容是：\(recentContext)")
        
        规则：
        - 语气自然随意，像是真人主动找朋友聊天
        - 可以根据最近聊天内容来接话（如果最近在聊某个话题就接着聊）
        - 如果没有上下文，就发个日常问候或分享一件小事
        - 简短，1-2句话
        - 用中文
        """
        
        let messages: [[String: String]] = [
            ["role": "system", "content": effectivePrompt(for: contactName)],
            ["role": "user", "content": prompt]
        ]
        
        let requestBody: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": 300,
            "temperature": 0.8,
            "stream": false
        ]
        
        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        request.timeoutInterval = 30
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw DeepSeekError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw DeepSeekError.parseError
        }
        
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Supporting Types

struct ChatPair {
    let incoming: String
    let outgoing: String
}

enum DeepSeekError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case httpError(statusCode: Int)
    case apiError(statusCode: Int, body: String)
    case parseError
    
    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "请在设置中配置 DeepSeek API Key"
        case .invalidResponse:
            return "无效的服务器响应"
        case .httpError(let code):
            return "HTTP 错误: \(code)"
        case .apiError(let code, let body):
            return "API 错误 (\(code)): \(body)"
        case .parseError:
            return "解析响应失败"
        }
    }
}
