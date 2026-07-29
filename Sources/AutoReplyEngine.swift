import Foundation
import Combine

// MARK: - Auto-Reply Engine
// Monitors currently open WeChat chat, generates replies with human-like delays

@MainActor
class AutoReplyEngine: ObservableObject {
    static let shared = AutoReplyEngine()
    
    private let bridge = WeChatBridge.shared
    private let deepseek = DeepSeekClient.shared
    
    @Published var isRunning = false
    @Published var statusMessage = "就绪"
    @Published var lastCheckTime: Date?
    @Published var processedCount = 0
    @Published var currentChatName: String?
    @Published var isSendingFirstMessage = false
    
    // Conversation memory for the current chat
    private var conversationHistory: [ChatPair] = []
    
    // Last seen messages to detect new ones
    private var lastSeenMessageTexts: Set<String> = []
    
    // Track messages we sent (trimmed) to avoid replying to ourselves
    private var sentMessageTexts: Set<String> = []
    
    // First poll flag — skip existing messages on startup
    private var isFirstPoll = true
    
    // Polling timer
    private var pollingTimer: Timer?
    
    // MARK: - Settings
    
    var pollingInterval: TimeInterval {
        get { let v = UserDefaults.standard.double(forKey: "polling_interval"); return v > 0 ? v : 3.0 }
        set { UserDefaults.standard.set(newValue, forKey: "polling_interval") }
    }
    
    var minReplyDelay: TimeInterval {
        get { let v = UserDefaults.standard.double(forKey: "min_reply_delay"); return v > 0 ? v : 3.0 }
        set { UserDefaults.standard.set(newValue, forKey: "min_reply_delay") }
    }
    
    var maxReplyDelay: TimeInterval {
        get { let v = UserDefaults.standard.double(forKey: "max_reply_delay"); return v > 0 ? v : 15.0 }
        set { UserDefaults.standard.set(newValue, forKey: "max_reply_delay") }
    }
    
    var skipProbability: Double {
        get { let v = UserDefaults.standard.double(forKey: "skip_probability"); return v >= 0 ? v : 0.2 }
        set { UserDefaults.standard.set(newValue, forKey: "skip_probability") }
    }
    
    var workHoursStart: Int? {
        get { let v = UserDefaults.standard.integer(forKey: "work_hours_start"); return UserDefaults.standard.object(forKey: "work_hours_start") != nil ? v : nil }
        set { if let h = newValue { UserDefaults.standard.set(h, forKey: "work_hours_start") } else { UserDefaults.standard.removeObject(forKey: "work_hours_start") } }
    }
    
    var workHoursEnd: Int? {
        get { let v = UserDefaults.standard.integer(forKey: "work_hours_end"); return UserDefaults.standard.object(forKey: "work_hours_end") != nil ? v : nil }
        set { if let h = newValue { UserDefaults.standard.set(h, forKey: "work_hours_end") } else { UserDefaults.standard.removeObject(forKey: "work_hours_end") } }
    }
    
    var workHoursEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "work_hours_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "work_hours_enabled") }
    }
    
    // MARK: - Start / Stop
    
    func start() {
        guard !isRunning else { return }
        guard bridge.hasAccessibilityPermission else { statusMessage = "需要辅助功能权限"; bridge.requestAccessibilityPermission(); return }
        guard bridge.isWeChatRunning else { statusMessage = "微信未运行"; return }
        guard !deepseek.apiKey.isEmpty else { statusMessage = "请配置 API Key"; return }
        
        isRunning = true
        isFirstPoll = true  // Reset first poll flag
        statusMessage = "运行中..."
        
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkMessages() }
        }
        Task { await checkMessages() }
    }
    
    func stop() {
        isRunning = false
        pollingTimer?.invalidate()
        pollingTimer = nil
        statusMessage = "已停止"
    }
    
    // MARK: - Message Checking
    
    private func checkMessages() async {
        guard isRunning else { return }
        
        // Work hours check
        if workHoursEnabled, let start = workHoursStart, let end = workHoursEnd {
            let hour = Calendar.current.component(.hour, from: Date())
            if start <= end {
                if hour < start || hour >= end { statusMessage = "工作时间外 (\(start):00-\(end):00)"; return }
            } else {
                if hour < start && hour >= end { statusMessage = "工作时间外"; return }
            }
        }
        
        statusMessage = "检查消息中..."
        lastCheckTime = Date()
        currentChatName = bridge.getCurrentChatName() ?? "未知聊天"
        
        let rawMessages = bridge.getCurrentChatMessages()
        
        // First poll: seed seen-set, don't reply to existing messages
        if isFirstPoll {
            isFirstPoll = false
            for msg in rawMessages { lastSeenMessageTexts.insert(msg) }
            statusMessage = "就绪 (已加载 \(rawMessages.count) 条历史)"
            return
        }
        
        guard !rawMessages.isEmpty else { statusMessage = "无新消息"; return }
        
        // Detect new messages
        let newMessages = rawMessages.filter { !lastSeenMessageTexts.contains($0) }
        for msg in rawMessages { lastSeenMessageTexts.insert(msg) }
        if lastSeenMessageTexts.count > 300 {
            lastSeenMessageTexts = Set(rawMessages.suffix(100))
        }
        
        // Filter noise
        let filtered = newMessages.filter { text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip our own sent messages (trimmed + fuzzy for long messages)
            for sent in sentMessageTexts {
                if trimmed == sent { return false }
                // Fuzzy: only for longer messages to avoid false positives
                if sent.count >= 6 && (trimmed.contains(sent) || sent.contains(trimmed)) {
                    return false
                }
            }
            if isTimestamp(trimmed) { return false }
            let noise = ["你撤回了一条消息","对方撤回了一条消息","以上是打招呼的内容","你已添加了",
                         "Accepted WeChat Transfer","Transfer","发来一个","发来一张","发来一段",
                         "置顶","视频通话","语音通话","Stuck on Top","Mute Notifications"]
            for p in noise { if text.contains(p) { return false } }
            if text.count < 3 { return false }
            if text.hasPrefix("【自动回复") { return false }
            return true
        }
        
        guard !filtered.isEmpty else { statusMessage = "无新消息"; return }
        
        // If multiple new messages, combine into one context-aware reply
        if filtered.count > 1 {
            statusMessage = "收到 \(filtered.count) 条新消息"
            let combined = filtered.joined(separator: "\n---\n")
            await processMessage(combined, messageCount: filtered.count)
        } else {
            await processMessage(filtered[0], messageCount: 1)
        }
    }
    
    private func processMessage(_ message: String, messageCount: Int = 1) async {
        let label = messageCount > 1 ? "\(messageCount)条消息" : "消息"
        
        if Double.random(in: 0...1) < skipProbability {
            statusMessage = "跳过回复 - \(label)"
            AppLogger.shared.log("跳过", message: message)
            return
        }
        
        statusMessage = "AI 思考中..."
        AppLogger.shared.log("收到\(label)", message: message.prefix(100).description)
        
        do {
            let reply = try await deepseek.generateReply(
                for: message,
                contactName: currentChatName ?? "联系人",
                conversationHistory: conversationHistory
            )
            
            guard !reply.isEmpty, isRunning else { return }
            
            statusMessage = "已生成回复 (\(reply.count)字)"
            
            let delay = Double.random(in: minReplyDelay...maxReplyDelay)
            let delayInt = Int(delay)
            
            // Countdown status
            for remaining in stride(from: delayInt, through: 1, by: -1) {
                guard isRunning else { return }
                statusMessage = "\(remaining)秒后回复..."
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            
            guard isRunning else { return }
            
            statusMessage = "正在输入..."
            let success = bridge.sendMessageHumanLike(reply)
            
            if success {
                processedCount += 1
                sentMessageTexts.insert(reply.trimmingCharacters(in: .whitespacesAndNewlines))
                AppLogger.shared.log("回复", message: reply)
                conversationHistory.append(ChatPair(incoming: message, outgoing: reply))
                if conversationHistory.count > 20 { conversationHistory = Array(conversationHistory.suffix(20)) }
                statusMessage = "已回复 (\(processedCount) 条)"
            } else {
                statusMessage = "发送失败"
            }
        } catch {
            statusMessage = "错误: \(error.localizedDescription)"
            AppLogger.shared.log("错误", message: error.localizedDescription)
        }
    }
    
    // MARK: - Proactive Message
    
    func sendFirstMessage() async {
        guard !isSendingFirstMessage else { return }
        isSendingFirstMessage = true
        defer { isSendingFirstMessage = false }
        
        statusMessage = "生成开场白..."
        currentChatName = bridge.getCurrentChatName() ?? "联系人"
        let recentMessages = bridge.getCurrentChatMessages()
        let context = recentMessages.suffix(5).joined(separator: " | ")
        
        do {
            let reply = try await deepseek.generateFirstMessage(
                contactName: currentChatName ?? "联系人",
                recentContext: context
            )
            guard !reply.isEmpty else { return }
            
            let delay = Double.random(in: 1.0...3.0)
            let delayInt = Int(delay)
            for remaining in stride(from: delayInt, through: 1, by: -1) {
                statusMessage = "\(remaining)秒后发送..."
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            
            statusMessage = "正在输入..."
            let success = bridge.sendMessageHumanLike(reply)
            
            if success {
                processedCount += 1
                sentMessageTexts.insert(reply.trimmingCharacters(in: .whitespacesAndNewlines))
                AppLogger.shared.log("主动发送", message: reply)
                conversationHistory.append(ChatPair(incoming: "", outgoing: reply))
                statusMessage = "已发送 (\(processedCount) 条)"
            } else {
                statusMessage = "发送失败 - 找不到输入框"
            }
        } catch {
            statusMessage = "错误: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Management
    
    func resetConversationHistory() {
        conversationHistory.removeAll()
        lastSeenMessageTexts.removeAll()
        sentMessageTexts.removeAll()
        isFirstPoll = true
    }
}

// MARK: - Helpers

/// Check if a string looks like a timestamp (not a real message)
private func isTimestamp(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard trimmed.count <= 30 else { return false }
    
    // "21:08"
    if trimmed.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil { return true }
    // "Friday 20:57", "Monday 08:30"
    if trimmed.range(of: #"^(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\s+\d{1,2}:\d{2}$"#, options: .regularExpression) != nil { return true }
    // "Yesterday 19:21", "昨天 20:57", "今天 08:30"
    if trimmed.range(of: #"^(Yesterday|Today|昨天|今天|前天)\s+\d{1,2}:\d{2}$"#, options: .regularExpression) != nil { return true }
    // "07/21"
    if trimmed.range(of: #"^\d{2}/\d{2}$"#, options: .regularExpression) != nil { return true }
    // Short texts containing ":" (like "18:06")
    if trimmed.count <= 5 && trimmed.contains(":") { return true }
    
    return false
}

// MARK: - App Logger

class AppLogger {
    static let shared = AppLogger()
    private var logEntries: [LogEntry] = []
    private let maxEntries = 200
    
    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let title: String
        let message: String
    }
    
    func log(_ title: String, message: String) {
        let entry = LogEntry(timestamp: Date(), title: title, message: message)
        logEntries.append(entry)
        if logEntries.count > maxEntries { logEntries.removeFirst(logEntries.count - maxEntries) }
    }
    
    func getRecentEntries(count: Int = 30) -> [LogEntry] {
        return Array(logEntries.suffix(count)).reversed()
    }
}
