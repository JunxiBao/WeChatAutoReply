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
    
    @Published var isManualReplying = false
    
    private var conversationHistory: [ChatPair] = []
    
    /// Set of message texts we have sent ourselves (trimmed).
    /// Used as secondary safeguard in addition to the isFromMe flag.
    private var sentMessageTexts: Set<String> = []
    
    /// Fingerprint of the last incoming (non-me) message we processed.
    /// Prevents re-processing the same message on the next poll cycle.
    private var lastSeenAllTexts: [String] = []
    
    /// Guard flag: prevents concurrent checkMessages runs (e.g. timer fires while
    /// a reply is still being generated / sent).
    @Published private(set) var isProcessingMessage = false
    
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
        
        // Baseline the current screen state so we DON'T reply to the old messages already on screen!
        lastSeenAllTexts = bridge.getCurrentChatMessages().map { $0.text }
        
        isRunning = true
        statusMessage = Loc.str("status.running")
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkMessages() }
        }
    }
    
    func stop() {
        isRunning = false; pollingTimer?.invalidate(); pollingTimer = nil
        isProcessingMessage = false
        statusMessage = Loc.str("status.stopped")
    }
    
    // MARK: - Message Checking
    
    private func checkMessages() async {
        guard isRunning else { return }
        // Prevent concurrent runs: if we're already generating/sending, skip this poll tick.
        guard !isProcessingMessage else { return }
        
        if workHoursEnabled, let start = workHoursStart, let end = workHoursEnd {
            let hour = Calendar.current.component(.hour, from: Date())
            // Normal range e.g. 9–23: block if hour is outside [start, end)
            if start <= end {
                if hour < start || hour >= end { statusMessage = Loc.str("status.work_hours"); return }
            } else {
                // Cross-midnight range e.g. 22–7: ALLOW if hour >= start OR hour < end
                // Block (return) if hour is in the gap: hour < start AND hour >= end
                if hour >= end && hour < start { statusMessage = Loc.str("status.work_hours"); return }
            }
        }
        statusMessage = Loc.str("status.checking")
        lastCheckTime = Date()
        currentChatName = bridge.getCurrentChatName() ?? Loc.str("status.unknown_chat")
        
        let allMessages = bridge.getCurrentChatMessages()
        guard !allMessages.isEmpty else { statusMessage = Loc.str("status.no_new"); return }
        
        let currentAllTexts = allMessages.map { $0.text }
        
        // 1. Check if chat has actually updated
        if !hasNewMessagesAtBottom(current: currentAllTexts, lastSeen: lastSeenAllTexts) {
            statusMessage = Loc.str("status.no_new")
            return
        }
        
        // Chat updated! Save state
        lastSeenAllTexts = currentAllTexts
        
        // 2. Filter out messages the AI already sent
        let incomingMessages = allMessages.filter { msg in
            let trimmed = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !sentMessageTexts.contains(trimmed)
        }
        
        guard !incomingMessages.isEmpty else { statusMessage = Loc.str("status.no_new"); return }
        
        // 3. If the VERY LAST message in the chat is from the AI, it means we are waiting for their reply.
        // We skip processing to prevent replying to older messages that are still on screen.
        if let rawLastText = currentAllTexts.last?.trimmingCharacters(in: .whitespacesAndNewlines),
           sentMessageTexts.contains(rawLastText) {
            statusMessage = Loc.str("status.no_new") // Or "等待对方回复"
            return
        }
        
        // 4. Process the latest incoming message
        await processMessage(incomingMessages[incomingMessages.count - 1].text, messageCount: 1)
    }
    
    private func hasNewMessagesAtBottom(current: [String], lastSeen: [String]) -> Bool {
        if current.isEmpty { return false }
        if lastSeen.isEmpty { return true }
        if current == lastSeen { return false }
        
        // If current is shorter, it might just be older messages scrolled off the top.
        // Check if current is exactly a suffix of lastSeen.
        if current.count < lastSeen.count {
            let suffix = Array(lastSeen.suffix(current.count))
            if current == suffix { return false }
        }
        
        return true
    }
    
    private func processMessage(_ message: String, messageCount: Int = 1) async {
        isProcessingMessage = true
        defer { isProcessingMessage = false }
        
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
            
            // Safe random range: ensure min <= max to avoid runtime crash
            let safeMin = min(minReplyDelay, maxReplyDelay)
            let safeMax = max(minReplyDelay, maxReplyDelay)
            let delayInt = Int(Double.random(in: safeMin...safeMax))
            for remaining in stride(from: delayInt, through: 1, by: -1) {
                guard isRunning else { return }
                statusMessage = Loc.f("status.countdown", remaining)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard isRunning else { return }
            
            // Register the reply in our sent-texts cache BEFORE sending,
            // so the next poll won't accidentally pick it up.
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
                
                // Update our state to reflect the new message we just sent
                lastSeenAllTexts = bridge.getCurrentChatMessages().map { $0.text }
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
        let ctx = bridge.getCurrentChatMessages().suffix(5).map { $0.text }.joined(separator: " | ")
        
        do {
            let reply = try await deepseek.generateFirstMessage(contactName: currentChatName ?? "?", recentContext: ctx)
            guard !reply.isEmpty else { return }
            let delayInt = Int(Double.random(in: 1.0...3.0))
            for remaining in stride(from: delayInt, through: 1, by: -1) {
                statusMessage = Loc.f("status.countdown", remaining)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            let trimmedReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            sentMessageTexts.insert(trimmedReply)
            statusMessage = Loc.str("status.typing")
            let success = await Task.detached { [bridge] in bridge.sendMessageHumanLike(reply) }.value
            if success {
                processedCount += 1
                AppLogger.shared.log(Loc.str("log.sent"), message: reply)
                conversationHistory.append(ChatPair(incoming: "", outgoing: reply))
                statusMessage = Loc.f("status.sent", processedCount)
                lastSeenAllTexts = bridge.getCurrentChatMessages().map { $0.text }
            } else {
                sentMessageTexts.remove(trimmedReply)
                statusMessage = Loc.str("status.failed")
            }
        } catch {
            statusMessage = Loc.f("status.error", error.localizedDescription)
        }
    }
    
    // MARK: - Manual Reply

    /// Manually trigger a reply to the latest incoming message,
    /// bypassing the fingerprint guard. Useful when auto-reply didn't fire.
    func manualReply() async {
        guard !isManualReplying, !isProcessingMessage else { return }
        guard bridge.hasAccessibilityPermission else { statusMessage = Loc.str("status.permission"); return }
        guard bridge.isWeChatRunning else { statusMessage = Loc.str("status.wechat_off"); return }
        guard !deepseek.apiKey.isEmpty else { statusMessage = Loc.str("status.api_key"); return }

        isManualReplying = true
        defer { isManualReplying = false }

        currentChatName = bridge.getCurrentChatName() ?? Loc.str("status.unknown_chat")
        let allMessages = bridge.getCurrentChatMessages()

        // Filter to the other person's messages only
        let incomingMessages = allMessages.filter { msg in
            guard !msg.isFromMe else { return false }
            let trimmed = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !sentMessageTexts.contains(trimmed)
        }

        guard let lastMsg = incomingMessages.last else {
            statusMessage = Loc.str("status.no_incoming")
            return
        }

        // Update state to prevent auto-reply picking it up immediately
        lastSeenAllTexts = allMessages.map { $0.text }
        
        // Process the latest message, ignoring fingerprint
        await processMessage(lastMsg.text, messageCount: 1)
    }

    func resetConversationHistory() {
        conversationHistory.removeAll()
        sentMessageTexts.removeAll()
        lastSeenAllTexts = []
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
