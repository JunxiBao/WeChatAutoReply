import Cocoa
import ApplicationServices

// MARK: - WeChat Accessibility Bridge
// Reads messages from currently open chat, sends replies with human-like typing

// MARK: - Data Models

/// A single chat message with sender information
struct WeChatMessage {
    let text: String
    let isFromMe: Bool
}

// MARK: - Bridge

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

    private func axFrame(_ elem: AXUIElement) -> CGRect {
        var pos: CGPoint = .zero
        var size: CGSize = .zero
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(elem, "AXPosition" as CFString, &value) == .success,
           let v = value {
            AXValueGetValue(v as! AXValue, .cgPoint, &pos)
        }
        value = nil
        if AXUIElementCopyAttributeValue(elem, "AXSize" as CFString, &value) == .success,
           let v = value {
            AXValueGetValue(v as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: pos, size: size)
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
        // AXFocusedWindow returns nil when no window is focused; only force-cast when non-nil
        if let raw = axAttr(app, "AXFocusedWindow") {
            return (raw as! AXUIElement)
        }
        // Fallback: first window in AXWindows list
        if let windows = axAttr(app, "AXWindows") as? [AXUIElement], let first = windows.first {
            return first
        }
        return nil
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

    /// Get all visible chat messages with sender information.
    /// Uses message bubble position to determine sender:
    /// - Right-aligned bubbles (center X > window center) = sent by me
    /// - Left-aligned bubbles = received from contact
    func getCurrentChatMessages() -> [WeChatMessage] {
        guard let window = getMainWindow() else { return [] }

        let windowFrame = axFrame(window)
        // AX coordinates are in SCREEN space (absolute pixels).
        // The chat panel starts ~250px from the window's left edge.
        // So the panel's left boundary in screen coords = windowFrame.minX + 250.
        // Use the window's own horizontal center as the left/right threshold:
        // contact messages appear on the LEFT half, my messages on the RIGHT half.
        let midXThreshold = windowFrame.midX

        // Strategy 1: Find AXList titled "Messages"
        let messageLists = findElements(window, matching: { [weak self] elem in
            guard let self = self else { return false }
            guard self.axStr(elem, "AXRole") == "AXList" else { return false }
            let title = self.axStr(elem, "AXTitle") ?? ""
            return title == "Messages" || title == "消息"
        }, maxDepth: 25)

        if let messageList = messageLists.first {
            return parseMessageList(messageList, midXThreshold: midXThreshold)
        }

        // Strategy 2: Find any AXScrollArea in the right panel and look for message rows
        let scrollAreas = findElements(window, matching: { [weak self] elem in
            guard let self = self else { return false }
            guard self.axStr(elem, "AXRole") == "AXScrollArea" else { return false }
            let frame = self.axFrame(elem)
            // Must be in the right panel area and tall enough to be the chat area
            return frame.origin.x > windowFrame.minX + 200 && frame.height > 300
        }, maxDepth: 15)

        for scrollArea in scrollAreas {
            let lists = findElements(scrollArea, matching: { [weak self] elem in
                guard let self = self else { return false }
                return self.axStr(elem, "AXRole") == "AXList"
            }, maxDepth: 5)
            if let list = lists.first {
                let result = parseMessageList(list, midXThreshold: midXThreshold)
                if !result.isEmpty { return result }
            }
        }

        // Strategy 3: Collect all AXStaticText elements in the right panel and guess sender by X
        let panelLeftEdge = windowFrame.minX + 250
        let texts = findElements(window, matching: { [weak self] elem in
            guard let self = self else { return false }
            guard self.axStr(elem, "AXRole") == "AXStaticText" else { return false }
            let frame = self.axFrame(elem)
            return frame.origin.x > panelLeftEdge && frame.width > 30 && frame.height > 10
        }, maxDepth: 30)

        return texts.compactMap { [weak self] elem -> WeChatMessage? in
            guard let self = self else { return nil }
            let text = self.axStr(elem, "AXValue") ?? self.axStr(elem, "AXTitle") ?? ""
            guard text.count >= 2 else { return nil }
            let frame = self.axFrame(elem)
            // Text bubble midX relative to window center: right = mine, left = contact's
            let isFromMe = frame.midX > midXThreshold
            return WeChatMessage(text: text, isFromMe: isFromMe)
        }
    }

    // MARK: - Private: Parse message list rows

    private func parseMessageList(_ list: AXUIElement, midXThreshold: CGFloat) -> [WeChatMessage] {
        var messages: [WeChatMessage] = []

        for row in axChildren(list) {
            // Extract all text elements from this row
            let textElems = findElements(row, matching: { [weak self] elem in
                guard let self = self else { return false }
                let role = self.axStr(elem, "AXRole") ?? ""
                return role == "AXStaticText" || role == "AXTextArea"
            }, maxDepth: 8)

            // Pick the text element with the most content.
            // IMPORTANT: also track ITS frame — the row frame spans full width and is
            // useless for left/right detection; the TEXT ELEMENT's frame tells us
            // which side of the chat the bubble sits on.
            var rowText = ""
            var textElemFrame: CGRect = .zero
            for elem in textElems {
                let t = axStr(elem, "AXValue") ?? axStr(elem, "AXTitle") ?? ""
                if t.count > rowText.count {
                    rowText = t
                    textElemFrame = axFrame(elem)
                }
            }

            // Fallback: read directly from the row element
            if rowText.isEmpty {
                rowText = axStr(row, "AXValue") ?? axStr(row, "AXTitle") ?? ""
                textElemFrame = axFrame(row)
            }

            guard rowText.count >= 2 else { continue }

            // Determine sender:
            // 1. Try AXDescription (most reliable when available)
            let desc = (axStr(row, "AXDescription") ?? "")
            let descLower = desc.lowercased()
            let isFromMe: Bool
            if descLower.hasPrefix("sent") || desc.hasPrefix("发出") || desc.hasPrefix("我说") {
                isFromMe = true
            } else if descLower.hasPrefix("received") || desc.hasPrefix("收到") {
                isFromMe = false
            } else {
                // Fallback: use the TEXT BUBBLE's midX (not the full-width row frame).
                // My messages appear on the right → midX > window center.
                // Contact messages appear on the left → midX < window center.
                isFromMe = textElemFrame.midX > midXThreshold
            }

            messages.append(WeChatMessage(text: rowText, isFromMe: isFromMe))
        }

        return messages
    }

    // MARK: - Find Input Field

    /// Find the chat input field
    func findInputField() -> AXUIElement? {
        guard let window = getMainWindow() else { return nil }

        let textAreas = findElements(window, matching: { [weak self] elem in
            guard let self = self else { return false }
            guard self.axStr(elem, "AXRole") == "AXTextArea" else { return false }
            let title = self.axStr(elem, "AXTitle") ?? ""
            // Exclude the search box, keep the chat input
            return title != "Search" && title != "搜索"
        }, maxDepth: 30)

        // Return the one with the largest area (chat input is bigger than others)
        return textAreas.max(by: { a, b in
            let fa = axFrame(a), fb = axFrame(b)
            return (fa.width * fa.height) < (fb.width * fb.height)
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

        weChat.unhide()
        weChat.activate()
        Thread.sleep(forTimeInterval: 0.8)

        var input: AXUIElement?
        for attempt in 1...3 {
            input = findInputField()
            if input != nil { break }
            print("[WeChatBridge] Input field not found, retry \(attempt)/3")
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let inputField = input else {
            print("[WeChatBridge] No input field after 3 retries")
            return false
        }

        AXUIElementSetAttributeValue(inputField, "AXFocused" as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.2)

        let source = CGEventSource(stateID: .hidSystemState)

        // Cmd+A to select all, then Delete to clear any residual content
        if let e = CGEvent(keyboardEventSource: source, virtualKey: 0x00, keyDown: true) { e.flags = .maskCommand; e.postToPid(weChatPID) }
        Thread.sleep(forTimeInterval: 0.05)
        if let e = CGEvent(keyboardEventSource: source, virtualKey: 0x00, keyDown: false) { e.flags = .maskCommand; e.postToPid(weChatPID) }
        Thread.sleep(forTimeInterval: 0.08)
        if let e = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true) { e.postToPid(weChatPID) }
        Thread.sleep(forTimeInterval: 0.05)
        if let e = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false) { e.postToPid(weChatPID) }
        Thread.sleep(forTimeInterval: 0.1)

        // Type each character with human-like timing
        for char in text {
            Thread.sleep(forTimeInterval: Double.random(in: 0.05...0.20))
            if Double.random(in: 0...1) < 0.1 { Thread.sleep(forTimeInterval: Double.random(in: 0.3...0.8)) }
            var chars = Array(String(char).utf16)
            if let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                e.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
                e.postToPid(weChatPID)
            }
            Thread.sleep(forTimeInterval: Double.random(in: 0.01...0.04))
            if let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) { e.postToPid(weChatPID) }
        }

        Thread.sleep(forTimeInterval: Double.random(in: 0.5...1.5))

        // Enter to send
        if let e = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true) { e.postToPid(weChatPID) }
        Thread.sleep(forTimeInterval: 0.05)
        if let e = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false) { e.postToPid(weChatPID) }

        return true
    }
}
