import Foundation
import Combine

@MainActor
class AutoReplyEngine: ObservableObject {
    static let shared = AutoReplyEngine()
    
    private let bridge = WeChatBridge.shared
    private let deepseek = DeepSeekClient.shared
    
    @Published var isRunning = false
    @Published var statusMessage = Loc.str("status.ready")
    @Published var lastCheckTime: Date?
    @Published var processedCount = 0
    @Published var currentChatName: String?
    @Published var isSendingFirstMessage = false
    
    private var conversationHistory: [ChatPair] = []
    private var sentMessageTexts: Set<String> = []
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
        guard bridge.hasAccessibilityPermission else { statusMessage = Loc.str("status.permission"); bridge.requestAccessibilityPermission(); return }
        guard bridge.isWeChatRunning else { statusMessage = Loc.str("status.wechat_off"); return }
        guard !deepseek.apiKey.isEmpty else { statusMessage = Loc.str("status.api_key"); return }
        isRunning = true
        statusMessage = Loc.str("status.running")
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkMessages() }
        }
        Task { await checkMessages() }
    }
    
    func stop() {
        isRunning = false; pollingTimer?.invalidate(); pollingTimer = nil
        statusMessage = Loc.str("status.stopped")
    }
    
    // MARK: - Message Checking
    
    private func checkMessages() async {
        guard isRunning else { return }
        if workHoursEnabled, let start = workHoursStart, let end = workHoursEnd {
            let hour = Calendar.current.component(.hour, from: Date())
            if start <= end { if hour < start || hour >= end { statusMessage = Loc.str("status.work_hours"); return } }
            else { if hour < start && hour >= end { statusMessage = Loc.str("status.work_hours"); return } }
        }
        statusMessage = Loc.str("status.checking")
        lastCheckTime = Date()
        currentChatName = bridge.getCurrentChatName() ?? Loc.str("status.unknown_chat")
        
        var messages = bridge.getCurrentChatMessages()
        guard !messages.isEmpty else { statusMessage = Loc.str("status.no_new"); return }
        
        // Only filter our own sent messages, nothing else
        messages = messages.filter { msg in
            let t = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            return !sentMessageTexts.contains(t)
        }
        guard !messages.isEmpty else { statusMessage = Loc.str("status.no_new"); return }
        
        if messages.count > 1 {
            statusMessage = Loc.f("status.multi_msgs", messages.count)
            await processMessage(messages.joined(separator: "\n---\n"), messageCount: messages.count)
        } else {
            await processMessage(messages[0], messageCount: 1)
        }
    }
    
    private func processMessage(_ message: String, messageCount: Int = 1) async {
        let label = messageCount > 1 ? String(format: Loc.str("status.n_msgs"), messageCount) : Loc.str("status.msg")
        if Double.random(in: 0...1) < skipProbability {
            statusMessage = String(format: Loc.str("status.skip"), label)
            AppLogger.shared.log(Loc.str("log.skip"), message: message)
            return
        }
        statusMessage = Loc.str("status.thinking")
        AppLogger.shared.log(String(format: Loc.str("log.received"), label), message: String(message.prefix(100)))
        
        do {
            let reply = try await deepseek.generateReply(for: message, contactName: currentChatName ?? "?", conversationHistory: conversationHistory)
            guard !reply.isEmpty, isRunning else { return }
            statusMessage = Loc.f("status.generated", reply.count)
            
            let delayInt = Int(Double.random(in: minReplyDelay...maxReplyDelay))
            for remaining in stride(from: delayInt, through: 1, by: -1) {
                guard isRunning else { return }
                statusMessage = Loc.f("status.countdown", remaining)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard isRunning else { return }
            
            let trimmedReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            sentMessageTexts.insert(trimmedReply)
            
            statusMessage = Loc.str("status.typing")
            let success = await Task.detached { [bridge] in bridge.sendMessageHumanLike(reply) }.value
            if success {
                processedCount += 1
                AppLogger.shared.log(Loc.str("log.reply"), message: reply)
                conversationHistory.append(ChatPair(incoming: message, outgoing: reply))
                if conversationHistory.count > 20 { conversationHistory = Array(conversationHistory.suffix(20)) }
                statusMessage = Loc.f("status.reply", processedCount)
            } else {
                sentMessageTexts.remove(trimmedReply)
                statusMessage = Loc.str("status.failed")
            }
        } catch {
            statusMessage = Loc.f("status.error", error.localizedDescription)
            AppLogger.shared.log(Loc.str("log.error"), message: error.localizedDescription)
        }
    }
    
    // MARK: - Proactive Message
    
    func sendFirstMessage() async {
        guard !isSendingFirstMessage else { return }
        isSendingFirstMessage = true; defer { isSendingFirstMessage = false }
        statusMessage = Loc.str("status.generating")
        currentChatName = bridge.getCurrentChatName() ?? "?"
        let ctx = bridge.getCurrentChatMessages().suffix(5).joined(separator: " | ")
        
        do {
            let reply = try await deepseek.generateFirstMessage(contactName: currentChatName ?? "?", recentContext: ctx)
            guard !reply.isEmpty else { return }
            let delayInt = Int(Double.random(in: 1.0...3.0))
            for remaining in stride(from: delayInt, through: 1, by: -1) {
                statusMessage = Loc.f("status.countdown", remaining)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            sentMessageTexts.insert(reply.trimmingCharacters(in: .whitespacesAndNewlines))
            statusMessage = Loc.str("status.typing")
            let success = await Task.detached { [bridge] in bridge.sendMessageHumanLike(reply) }.value
            if success {
                processedCount += 1
                AppLogger.shared.log(Loc.str("log.sent"), message: reply)
                conversationHistory.append(ChatPair(incoming: "", outgoing: reply))
                statusMessage = Loc.f("status.sent", processedCount)
            } else {
                sentMessageTexts.remove(reply.trimmingCharacters(in: .whitespacesAndNewlines))
                statusMessage = Loc.str("status.failed")
            }
        } catch {
            statusMessage = Loc.f("status.error", error.localizedDescription)
        }
    }
    
    func resetConversationHistory() {
        conversationHistory.removeAll()
        sentMessageTexts.removeAll()
    }
}

// MARK: - App Logger

class AppLogger {
    static let shared = AppLogger()
    private var logEntries: [LogEntry] = []; private let maxEntries = 200
    
    struct LogEntry: Identifiable { let id = UUID(); let timestamp: Date; let title: String; let message: String }
    
    func log(_ title: String, message: String) {
        logEntries.append(LogEntry(timestamp: Date(), title: title, message: message))
        if logEntries.count > maxEntries { logEntries.removeFirst(logEntries.count - maxEntries) }
    }
    func getRecentEntries(count: Int = 30) -> [LogEntry] { Array(logEntries.suffix(count)).reversed() }
}
