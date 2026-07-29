import SwiftUI
import AppKit

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private let engine = AutoReplyEngine.shared
    private let bridge = WeChatBridge.shared
    private var statusUpdateTimer: Timer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Show in Dock (regular app), don't quit when window closes
        NSApp.setActivationPolicy(.regular)
        setupMenuBar()
        
        // Always open settings on launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.openSettings()
        }
        
        // Only show accessibility alert if user is trying to use the app
        // (not on every launch, since re-signing resets permission)
    }
    
    // Check permission quietly, only show alert when user tries to start
    func ensureAccessibilityPermission() -> Bool {
        if !bridge.hasAccessibilityPermission {
            showAccessibilityAlert()
            return false
        }
        return true
    }
    
    // MARK: - Menu Bar
    
    var hideMenuBarIcon: Bool {
        get { UserDefaults.standard.bool(forKey: "hide_menu_bar_icon") }
        set {
            UserDefaults.standard.set(newValue, forKey: "hide_menu_bar_icon")
            if newValue { removeMenuBar() } else { if statusItem == nil { setupMenuBar() } }
        }
    }
    
    private func setupMenuBar() {
        guard !hideMenuBarIcon else { return }
        guard statusItem == nil else { return }
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.title = "💬"
            button.toolTip = "微信自动回复"
        }
        
        let menu = NSMenu()
        
        let statusMenuItem = NSMenuItem(title: "状态: 就绪", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        menu.addItem(.separator())
        
        let toggleItem = NSMenuItem(title: "启动自动回复", action: #selector(toggleEngine), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        
        menu.addItem(.separator())
        
        menu.addItem(NSMenuItem(title: "设置...", action: #selector(openSettings), keyEquivalent: ","))
        
        menu.addItem(.separator())
        
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        
        statusItem?.menu = menu
        
        statusUpdateTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateMenuStatus(toggleItem, statusMenuItem)
            }
        }
    }
    
    private func removeMenuBar() {
        statusUpdateTimer?.invalidate()
        statusUpdateTimer = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }
    
    private func updateMenuStatus(_ toggleItem: NSMenuItem, _ statusMenuItem: NSMenuItem) {
        toggleItem.title = engine.isRunning ? "停止自动回复" : "启动自动回复"
        
        if engine.isRunning {
            statusMenuItem.title = "状态: 运行中 · 已回复 \(engine.processedCount) 条"
            if let button = statusItem?.button { button.title = "🟢" }
        } else {
            statusMenuItem.title = "状态: 已停止"
            if let button = statusItem?.button { button.title = "💬" }
        }
    }
    
    // MARK: - Actions
    
    @objc private func toggleEngine() {
        if engine.isRunning {
            engine.stop()
        } else {
            guard ensureAccessibilityPermission() else { return }
            guard bridge.isWeChatRunning else {
                showAlert(message: "微信未运行", info: "请先打开微信并打开一个聊天窗口")
                return
            }
            guard !DeepSeekClient.shared.apiKey.isEmpty else {
                openSettings()
                showAlert(message: "请先配置 API Key", info: "在设置中填入 DeepSeek API Key")
                return
            }
            engine.start()
        }
    }
    
    @objc private func openSettings() {
        if settingsWindow == nil {
            createSettingsWindow()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func quit() {
        engine.stop()
        NSApp.terminate(nil)
    }
    
    // MARK: - Settings Window
    
    private func createSettingsWindow() {
        let contentView = SettingsView()
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 480, height: 420)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "微信自动回复 · 设置"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("WeChatAutoReplySettings")
        
        settingsWindow = window
    }
    
    // Keep app alive when settings window is closed
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    // MARK: - Alerts
    
    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = """
        微信自动回复需要辅助功能权限才能读取消息和输入回复。
        
        请打开系统设置授予权限：
        系统设置 → 隐私与安全性 → 辅助功能
        找到 WeChatAutoReply 并打开开关
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        
        if alert.runModal() == .alertFirstButtonReturn {
            bridge.requestAccessibilityPermission()
        }
    }
    
    private func showAlert(message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }
}

// MARK: - Main Entry Point

private var appDelegate: AppDelegate?

@main
struct MainApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        appDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}
