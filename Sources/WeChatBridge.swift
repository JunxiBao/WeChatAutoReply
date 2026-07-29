import Cocoa
import ApplicationServices

// MARK: - WeChat Accessibility Bridge
// Reads messages from currently open chat, sends replies with human-like typing

class WeChatBridge {
    static let shared = WeChatBridge()
    
    // Check accessibility permission
    var hasAccessibilityPermission: Bool {
        return AXIsProcessTrusted()
    }
    
    func requestAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options)
    }
    
    var isWeChatRunning: Bool {
        let apps = NSWorkspace.shared.runningApplications
        return apps.contains { $0.localizedName?.contains("WeChat") == true }
    }
    
    // MARK: - AX Helpers
    
    private func getWeChatApp() -> AXUIElement? {
        let apps = NSWorkspace.shared.runningApplications
        guard let wc = apps.first(where: { $0.localizedName?.contains("WeChat") == true }) else {
            return nil
        }
        return AXUIElementCreateApplication(wc.processIdentifier)
    }
    
    private func axAttr(_ elem: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(elem, attr as CFString, &value)
        return value
    }
    
    private func axStr(_ elem: AXUIElement, _ attr: String) -> String? {
        return axAttr(elem, attr) as? String
    }
    
    private func axPos(_ elem: AXUIElement) -> CGPoint {
        var pos: CGPoint = .zero
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elem, "AXPosition" as CFString, &value) == .success,
              let v = value else { return pos }
        AXValueGetValue(v as! AXValue, .cgPoint, &pos)
        return pos
    }
    
    private func axChildren(_ elem: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(elem, "AXChildren" as CFString, &value)
        guard result == .success, let array = value as? [AXUIElement] else { return [] }
        return array
    }
    
    private func findElements(_ root: AXUIElement, matching: (AXUIElement) -> Bool, maxDepth: Int = 25) -> [AXUIElement] {
        var results: [AXUIElement] = []
        if matching(root) { results.append(root) }
        guard maxDepth > 0 else { return results }
        for child in axChildren(root) {
            results.append(contentsOf: findElements(child, matching: matching, maxDepth: maxDepth - 1))
        }
        return results
    }
    
    // MARK: - Get Current Chat Window
    
    func getMainWindow() -> AXUIElement? {
        guard let app = getWeChatApp() else { return nil }
        return axAttr(app, "AXFocusedWindow") as! AXUIElement?
    }
    
    // MARK: - Read Messages
    
    /// Get chat name of the currently open chat
    func getCurrentChatName() -> String? {
        guard let window = getMainWindow() else { return nil }
        
        // Try window title first (fallback: WeChat always returns "WeChat")
        if let title = axStr(window, "AXTitle"), !title.isEmpty && title != "WeChat" {
            return title
        }
        
        // Find the chat header - a StaticText at the top of the right panel
        // The input field's AXTitle IS the contact name
        if let input = findInputField(),
           let name = axStr(input, "AXTitle"), !name.isEmpty {
            return name
        }
        
        return nil
    }
    
    /// Get all visible chat messages from the current chat
    func getCurrentChatMessages() -> [String] {
        guard let window = getMainWindow() else { return [] }
        
        // Find the Messages list
        let messageLists = findElements(window, matching: { elem in
            guard axStr(elem, "AXRole") == "AXList" else { return false }
            return axStr(elem, "AXTitle") == "Messages"
        }, maxDepth: 25)
        
        guard let messageList = messageLists.first else {
            // Fallback: find StaticText in right panel area
            let texts = findElements(window, matching: { elem in
                guard axStr(elem, "AXRole") == "AXStaticText" else { return false }
                let pos = axPos(elem)
                return pos.x > 250 && pos.x < 500 && pos.y > 140 && pos.y < 640
            }, maxDepth: 30)
            return texts.compactMap { elem in
                let text = axStr(elem, "AXValue") ?? ""
                return text.count >= 2 ? text : nil
            }
        }
        
        // Read messages from the list's children
        var messages: [String] = []
        for child in axChildren(messageList) {
            if let text = axStr(child, "AXValue"), text.count >= 2 {
                messages.append(text)
            } else if let title = axStr(child, "AXTitle"), title.count >= 2 {
                messages.append(title)
            }
        }
        
        return messages
    }
    
    /// Find the chat input field
    func findInputField() -> AXUIElement? {
        guard let window = getMainWindow() else { return nil }
        
        let textAreas = findElements(window, matching: { elem in
            guard axStr(elem, "AXRole") == "AXTextArea" else { return false }
            let title = axStr(elem, "AXTitle") ?? ""
            // Exclude the search box, keep the chat input
            return title != "Search"
        }, maxDepth: 30)
        
        // Return the one with the largest size (chat input is bigger than search)
        return textAreas.max(by: { a, b in
            var sa = CGSize.zero, sb = CGSize.zero
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(a, "AXSize" as CFString, &v) == .success, let av = v {
                AXValueGetValue(av as! AXValue, .cgSize, &sa)
            }
            if AXUIElementCopyAttributeValue(b, "AXSize" as CFString, &v) == .success, let bv = v {
                AXValueGetValue(bv as! AXValue, .cgSize, &sb)
            }
            return (sa.width * sa.height) < (sb.width * sb.height)
        })
    }
    
    // MARK: - Send Message (human-like typing)
    
    /// Send a message with human-like typing simulation
    func sendMessageHumanLike(_ text: String) -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        guard let weChat = apps.first(where: { $0.localizedName?.contains("WeChat") == true }) else {
            print("[WeChatBridge] WeChat not running")
            return false
        }
        let weChatPID = weChat.processIdentifier
        
        // Force WeChat to front
        weChat.unhide()
        weChat.activate()
        Thread.sleep(forTimeInterval: 0.8)
        
        // Retry finding input field up to 3 times
        var inputField: AXUIElement?
        for attempt in 1...3 {
            inputField = findInputField()
            if inputField != nil { break }
            print("[WeChatBridge] Input field not found, retry \(attempt)/3")
            Thread.sleep(forTimeInterval: 0.5)
        }
        
        guard let input = inputField else {
            print("[WeChatBridge] No input field after 3 retries")
            return false
        }
        
        // Focus the input field via accessibility
        AXUIElementSetAttributeValue(input, "AXFocused" as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.2)
        
        // Clear existing text - Cmd+A then Delete
        let source = CGEventSource(stateID: .hidSystemState)
        
        // Cmd+A (select all)
        if let cmdA = CGEvent(keyboardEventSource: source, virtualKey: 0x00, keyDown: true) {
            cmdA.flags = .maskCommand
            cmdA.postToPid(weChatPID)
        }
        Thread.sleep(forTimeInterval: 0.05)
        if let cmdAUp = CGEvent(keyboardEventSource: source, virtualKey: 0x00, keyDown: false) {
            cmdAUp.flags = .maskCommand  // mirrors keyDown
            cmdAUp.postToPid(weChatPID)
        }
        Thread.sleep(forTimeInterval: 0.08)
        
        // Delete
        if let del = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true) {
            del.postToPid(weChatPID)
        }
        Thread.sleep(forTimeInterval: 0.05)
        if let delUp = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false) {
            delUp.postToPid(weChatPID)
        }
        Thread.sleep(forTimeInterval: 0.1)
        
        // Type each character with random delays
        for char in text {
            let delay = Double.random(in: 0.05...0.20)
            Thread.sleep(forTimeInterval: delay)
            
            // Occasional thinking pause
            if Double.random(in: 0...1) < 0.1 {
                Thread.sleep(forTimeInterval: Double.random(in: 0.3...0.8))
            }
            
            let str = String(char)
            var chars = Array(str.utf16)
            
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                keyDown.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
                keyDown.postToPid(weChatPID)
            }
            Thread.sleep(forTimeInterval: Double.random(in: 0.01...0.04))
            
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                keyUp.postToPid(weChatPID)
            }
        }
        
        // Pause before sending (like reviewing)
        Thread.sleep(forTimeInterval: Double.random(in: 0.5...1.5))
        
        // Press Enter
        if let enter = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true) {
            enter.postToPid(weChatPID)
        }
        Thread.sleep(forTimeInterval: 0.05)
        if let enterUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false) {
            enterUp.postToPid(weChatPID)
        }
        
        return true
    }
}

// MARK: - Data Models

struct ChatMessage {
    let text: String
    let isFromMe: Bool
}

struct ConversationState: Codable {
    var messages: [MessageRecord]
    var lastMessageId: String?
}

struct MessageRecord: Codable {
    let text: String
    let timestamp: Date
    let isFromMe: Bool
}
