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
        NSApp.setActivationPolicy(.regular)
        setupMainMenu()
        setupMenuBar()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.openSettings()
        }
    }
    
    // MARK: - Main Menu
    
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: Loc.str("app.name"), action: nil, keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: Loc.str("btn.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        mainMenu.addItem(NSMenuItem().apply { $0.submenu = appMenu })
        
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: Loc.str("menu.undo"), action: #selector(UndoAction.undo), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: Loc.str("menu.redo"), action: #selector(RedoAction.redo), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: Loc.str("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: Loc.str("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: Loc.str("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: Loc.str("menu.select_all"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        mainMenu.addItem(NSMenuItem().apply { $0.submenu = editMenu })
        
        NSApp.mainMenu = mainMenu
    }
    
    private class UndoAction: NSObject {
        @objc static func undo(_ sender: Any?) { NSApp.sendAction(Selector(("undo:")), to: nil, from: sender) }
    }
    private class RedoAction: NSObject {
        @objc static func redo(_ sender: Any?) { NSApp.sendAction(Selector(("redo:")), to: nil, from: sender) }
    }
    
    func ensureAccessibilityPermission() -> Bool {
        if !bridge.hasAccessibilityPermission { showAccessibilityAlert(); return false }
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
        guard !hideMenuBarIcon, statusItem == nil else { return }
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: nil)
        statusItem?.button?.toolTip = Loc.str("app.name")
        
        let menu = NSMenu()
        let statusMenuItem = NSMenuItem(title: String(format: Loc.str("menu.status"), Loc.str("status.ready")), action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        
        let toggleItem = NSMenuItem(title: Loc.str("menu.toggle_start"), action: #selector(toggleEngine), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: Loc.str("btn.settings"), action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: Loc.str("btn.quit"), action: #selector(quit), keyEquivalent: "q"))
        
        statusItem?.menu = menu
        
        statusUpdateTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateMenuStatus(toggleItem, statusMenuItem) }
        }
    }
    
    private func removeMenuBar() {
        statusUpdateTimer?.invalidate(); statusUpdateTimer = nil
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item); statusItem = nil }
    }
    
    private func updateMenuStatus(_ toggleItem: NSMenuItem, _ statusMenuItem: NSMenuItem) {
        toggleItem.title = engine.isRunning ? Loc.str("menu.toggle_stop") : Loc.str("menu.toggle_start")
        if engine.isRunning {
            statusMenuItem.title = String(format: Loc.str("menu.running_status"), engine.processedCount)
            statusItem?.button?.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill", accessibilityDescription: nil)
        } else {
            statusMenuItem.title = String(format: Loc.str("menu.status"), Loc.str("status.stopped"))
            statusItem?.button?.image = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: nil)
        }
    }
    
    // MARK: - Actions
    
    @objc private func toggleEngine() {
        if engine.isRunning { engine.stop() }
        else {
            guard ensureAccessibilityPermission() else { return }
            guard bridge.isWeChatRunning else { showAlert(message: Loc.str("alert.wechat_off")); return }
            guard !DeepSeekClient.shared.apiKey.isEmpty else { openSettings(); showAlert(message: Loc.str("alert.api_key")); return }
            engine.start()
        }
    }
    
    @objc private func openSettings() {
        if settingsWindow == nil { createSettingsWindow() }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func quit() { engine.stop(); NSApp.terminate(nil) }
    
    // MARK: - Settings Window
    
    private func createSettingsWindow() {
        let contentView = SettingsView()
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 480, height: 420)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = Loc.str("app.name")
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("WeChatAutoReplySettings")
        settingsWindow = window
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    
    // MARK: - Alerts
    
    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = Loc.str("alert.permission_title")
        alert.informativeText = Loc.str("alert.permission_body")
        alert.alertStyle = .warning
        alert.addButton(withTitle: Loc.str("alert.permission_btn"))
        alert.addButton(withTitle: Loc.str("alert.permission_later"))
        if alert.runModal() == .alertFirstButtonReturn { bridge.requestAccessibilityPermission() }
    }
    
    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: Loc.str("alert.ok"))
        alert.runModal()
    }
}

// MARK: - Helpers

extension NSMenuItem {
    func apply(_ block: (NSMenuItem) -> Void) -> NSMenuItem { block(self); return self }
}

// MARK: - Main

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
