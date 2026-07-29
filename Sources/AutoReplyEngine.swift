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
    
    /// Set of message texts we have sent ourselves (trimmed).
    /// Used as secondary safeguard in addition to the isFromMe flag.
    private var sentMessageTexts: Set<String> = []
    
    /// Fingerprint of the last incoming (non-me) message we processed.
    /// Prevents re-processing the same message on the next poll cycle.
    private var lastIncomingFingerprint: String = ""
    
    /// Guard flag: prevents concurrent checkMessages runs (e.g. timer fires while
    /// a reply is still being generated / sent).
    private var isProcessingMessage = false
    
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
        
        // Step 1: Filter to only messages from the other person (not from me).
        // This is the primary defense against replying to our own messages.
        let incomingMessages = allMessages.filter { msg in
            // Primary filter: AX-detected sender
            guard !msg.isFromMe else { return false }
            // Secondary filter: check against our sent texts cache (handles edge cases)
            let trimmed = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !sentMessageTexts.contains(trimmed)
        }
        
        guard !incomingMessages.isEmpty else { statusMessage = Loc.str("status.no_new"); return }
        
        // Step 2: Check if there are NEW incoming messages since last poll.
        // Compute a fingerprint from the last incoming message (text + count).
        // If the fingerprint hasn't changed, the same messages are still on screen → skip.
        let fingerprint = computeFingerprint(incomingMessages)
        guard fingerprint != lastIncomingFingerprint else {
            statusMessage = Loc.str("status.no_new")
            return
        }
        
        // New incoming messages detected - update fingerprint and process.
        // Only send the LAST message to the AI — visible messages include old history;
        // replying to all of them at once would confuse the AI and flood the conversation.
        lastIncomingFingerprint = fingerprint
        await processMessage(incomingMessages[incomingMessages.count - 1].text, messageCount: 1)
    }
    
    /// Compute a stable fingerprint for a list of messages to detect changes.
    /// Includes ALL visible incoming message texts so that:
    /// - Same screen content → same fingerprint → skip (no duplicate reply)
    /// - Contact sends same text again → count changes → different fingerprint → reply
    /// - Contact sends different text → last text changes → different fingerprint → reply
    private func computeFingerprint(_ messages: [WeChatMessage]) -> String {
        // Join all texts with a separator unlikely to appear in normal messages.
        // Using count + all texts makes it robust against same-last-text collisions.
        let allTexts = messages.map { $0.text }.joined(separator: "\u{0}")
        return "\(messages.count)|\(allTexts)"
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
                // Do NOT reset lastIncomingFingerprint here.
                // The fingerprint was already set to the current screen state in checkMessages().
                // Resetting to "" would cause the next poll to re-process the same old
                // messages still visible on screen. The fingerprint will naturally update
                // when the contact sends a new message (count or text will change).
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
                lastIncomingFingerprint = ""
            } else {
                sentMessageTexts.remove(trimmedReply)
                statusMessage = Loc.str("status.failed")
            }
        } catch {
            statusMessage = Loc.f("status.error", error.localizedDescription)
        }
    }
    
    func resetConversationHistory() {
        conversationHistory.removeAll()
        sentMessageTexts.removeAll()
        lastIncomingFingerprint = ""
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
