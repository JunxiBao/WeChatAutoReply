import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine = AutoReplyEngine.shared
    @State private var apiKey: String = ""
    @State private var systemPrompt: String = ""
    @State private var pollingInterval: Double = 3.0
    @State private var minReplyDelay: Double = 3.0
    @State private var maxReplyDelay: Double = 15.0
    @State private var skipProbability: Double = 0.2
    @State private var workHoursEnabled: Bool = false
    @State private var workHoursStart: Double = 9
    @State private var workHoursEnd: Double = 23
    @State private var hideMenuBar: Bool = UserDefaults.standard.bool(forKey: "hide_menu_bar_icon")
    @State private var contactPrompts: [String: String] = [:]
    @State private var newContactName: String = ""
    @State private var newContactPrompt: String = ""
    @State private var editingContactName: String? = nil
    @State private var refreshID = UUID()
    
    var body: some View {
        TabView {
            generalTab.tabItem { Label(Loc.str("tab.general"), systemImage: "gearshape") }
            promptTab.tabItem { Label(Loc.str("tab.prompt"), systemImage: "text.quote") }
            contactPromptTab.tabItem { Label(Loc.str("tab.contacts"), systemImage: "person.text.rectangle") }
            logTab.tabItem { Label(Loc.str("tab.logs"), systemImage: "list.bullet.rectangle") }
        }
        .id(refreshID)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 380, idealHeight: 440)
        .onAppear { loadSettings() }
        .onReceive(NotificationCenter.default.publisher(for: .languageChanged)) { _ in
            refreshID = UUID()
        }
    }
    
    // MARK: - General
    
    var generalTab: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    PasteableSecureField("sk-...", text: $apiKey)
                        .frame(height: 22)
                        .onChange(of: apiKey) { _, v in DeepSeekClient.shared.apiKey = v }
                    Label("platform.deepseek.com", systemImage: "info.circle").font(.caption).foregroundColor(.secondary)
                }
            } header: { Text(Loc.str("section.api")).fontWeight(.semibold) }
            
            Section {
                LabeledContent(Loc.str("label.interval")) {
                    HStack(spacing: 6) {
                        Slider(value: $pollingInterval, in: 1...10, step: 0.5).frame(width: 90)
                        Text("\(String(format: "%.1f", pollingInterval)) s").font(.caption).monospacedDigit().foregroundColor(.secondary).frame(width: 42, alignment: .trailing)
                    }
                }.onChange(of: pollingInterval) { _, v in engine.pollingInterval = v }
            } header: { Text(Loc.str("section.polling")).fontWeight(.semibold) }
            
            Section {
                LabeledContent(Loc.str("label.min_delay")) {
                    HStack(spacing: 6) {
                        Slider(value: $minReplyDelay, in: 0...30, step: 0.5).frame(width: 90)
                        Text("\(String(format: "%.0f", minReplyDelay)) s").font(.caption).monospacedDigit().foregroundColor(.secondary).frame(width: 35, alignment: .trailing)
                    }
                }.onChange(of: minReplyDelay) { _, v in engine.minReplyDelay = v }
                LabeledContent(Loc.str("label.max_delay")) {
                    HStack(spacing: 6) {
                        Slider(value: $maxReplyDelay, in: 1...60, step: 0.5).frame(width: 90)
                        Text("\(String(format: "%.0f", maxReplyDelay)) s").font(.caption).monospacedDigit().foregroundColor(.secondary).frame(width: 35, alignment: .trailing)
                    }
                }.onChange(of: maxReplyDelay) { _, v in engine.maxReplyDelay = v }
            } header: { Text(Loc.str("section.delay")).fontWeight(.semibold) }
            
            Section {
                Picker(Loc.str("label.language"), selection: Binding(get: { Loc.language }, set: { Loc.language = $0 })) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle(Loc.str("label.hide_menubar"), isOn: $hideMenuBar)
                    .onChange(of: hideMenuBar) { _, v in (NSApp.delegate as? AppDelegate)?.hideMenuBarIcon = v }
                LabeledContent(Loc.str("label.skip")) {
                    HStack(spacing: 6) {
                        Slider(value: $skipProbability, in: 0...0.8, step: 0.05).frame(width: 90)
                        Text(String(format: "%.0f%%", skipProbability * 100)).font(.caption).monospacedDigit().foregroundColor(.secondary).frame(width: 34, alignment: .trailing)
                    }
                }.onChange(of: skipProbability) { _, v in engine.skipProbability = v }
                Toggle(Loc.str("label.limit_hours"), isOn: $workHoursEnabled)
                    .onChange(of: workHoursEnabled) { _, v in engine.workHoursEnabled = v }
                if workHoursEnabled {
                    HStack {
                        Text(Loc.str("label.from")).font(.caption).foregroundColor(.secondary)
                        Stepper("\(Int(workHoursStart)):00", value: $workHoursStart, in: 0...23).font(.caption)
                            .onChange(of: workHoursStart) { _, v in engine.workHoursStart = Int(v) }
                        Text(Loc.str("label.to")).font(.caption).foregroundColor(.secondary).padding(.leading, 4)
                        Stepper("\(Int(workHoursEnd)):00", value: $workHoursEnd, in: 1...24).font(.caption)
                            .onChange(of: workHoursEnd) { _, v in engine.workHoursEnd = Int(v) }
                    }
                }
            } header: { Text(Loc.str("section.behavior")).fontWeight(.semibold) }
            
            Section {
                LabeledContent(Loc.str("label.engine")) { StatusBadge(isRunning: engine.isRunning, text: engine.statusMessage) }
                if let chat = engine.currentChatName { LabeledContent(Loc.str("label.chat")) { Text(chat).foregroundColor(.secondary).font(.caption) } }
                LabeledContent(Loc.str("label.replied")) { Text("\(engine.processedCount)").foregroundColor(.secondary).font(.caption) }
                if let last = engine.lastCheckTime { LabeledContent(Loc.str("label.last_check")) { Text(last, style: .time).foregroundColor(.secondary).font(.caption) } }
            } header: { Text(Loc.str("section.status")).fontWeight(.semibold) }
            
            Section {
                HStack(spacing: 8) {
                    Button(engine.isRunning ? Loc.str("btn.stop") : Loc.str("btn.start")) {
                        saveSettings(); engine.isRunning ? engine.stop() : engine.start()
                    }.buttonStyle(.borderedProminent).controlSize(.regular).keyboardShortcut(.defaultAction)
                    if engine.isRunning {
                        Button { Task { await engine.sendFirstMessage() } } label: {
                            HStack(spacing: 3) {
                                if engine.isSendingFirstMessage { ProgressView().scaleEffect(0.55).frame(width: 10, height: 10) }
                                Text(Loc.str("btn.ai_send"))
                            }
                        }.disabled(engine.isSendingFirstMessage)
                        Button(Loc.str("btn.reset")) { engine.resetConversationHistory() }.controlSize(.regular)
                    }
                }
            }
        }.formStyle(.grouped)
    }
    
    // MARK: - Prompt
    
    var promptTab: some View {
        Form {
            Section {
                TextEditor(text: $systemPrompt).font(.system(size: 11, design: .monospaced)).frame(minHeight: 200).scrollContentBackground(.hidden)
                    .onChange(of: systemPrompt) { _, v in DeepSeekClient.shared.systemPrompt = v }
            } header: { Text(Loc.str("tab.prompt")).fontWeight(.semibold) }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Loc.str("prompt.recommended")).font(.caption).foregroundColor(.secondary)
                    Button(Loc.str("btn.default_prompt")) {
                        systemPrompt = Loc.str("prompt.default")
                        DeepSeekClient.shared.systemPrompt = systemPrompt
                    }
                }
            }
        }.formStyle(.grouped)
    }
    
    // MARK: - Contact Prompts
    
    var contactPromptTab: some View {
        Form {
            Section { Text(Loc.str("contact.hint")).font(.caption).foregroundColor(.secondary) }
            Section {
                HStack {
                    TextField(Loc.str("contact.name_placeholder"), text: $newContactName).textFieldStyle(.roundedBorder).disabled(editingContactName != nil)
                    Button(editingContactName != nil ? Loc.str("btn.update") : Loc.str("btn.add")) {
                        let name = (editingContactName ?? newContactName).trimmingCharacters(in: .whitespaces)
                        let prompt = newContactPrompt.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty, !prompt.isEmpty else { return }
                        contactPrompts[name] = prompt; saveContactPrompts()
                        newContactName = ""; newContactPrompt = ""; editingContactName = nil
                    }.disabled(newContactPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
                    if editingContactName != nil {
                        Button(Loc.str("btn.cancel")) { newContactName = ""; newContactPrompt = ""; editingContactName = nil }
                    }
                }
                TextEditor(text: $newContactPrompt).font(.system(size: 11, design: .monospaced)).frame(minHeight: 60)
            } header: {
                Text(editingContactName != nil ? String(format: Loc.str("contact.section_edit"), editingContactName!) : Loc.str("contact.section_add")).fontWeight(.semibold)
            }
            if !contactPrompts.isEmpty {
                Section {
                    ForEach(Array(contactPrompts.keys.sorted()), id: \.self) { name in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(name).fontWeight(.medium); Spacer()
                                Button(Loc.str("btn.edit")) { newContactName = name; newContactPrompt = contactPrompts[name] ?? ""; editingContactName = name }
                                Button(Loc.str("btn.delete")) {
                                    contactPrompts.removeValue(forKey: name); saveContactPrompts()
                                    if editingContactName == name { newContactName = ""; newContactPrompt = ""; editingContactName = nil }
                                }.foregroundColor(.red)
                            }
                            Text(contactPrompts[name] ?? "").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).lineLimit(3)
                        }.padding(.vertical, 2)
                    }
                } header: { Text(String(format: Loc.str("contact.section_list"), contactPrompts.count)).fontWeight(.semibold) }
            }
        }.formStyle(.grouped)
        .onAppear {
            contactPrompts = DeepSeekClient.shared.contactPrompts
            if let name = engine.currentChatName, !name.isEmpty { newContactName = name }
            else if let name = WeChatBridge.shared.getCurrentChatName(), !name.isEmpty { newContactName = name }
        }
    }
    
    // MARK: - Logs
    
    var logTab: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(AppLogger.shared.getRecentEntries()) { entry in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Circle().fill(entry.title.contains(Loc.str("log.reply")) || entry.title.contains(Loc.str("log.sent")) ? .green : entry.title.contains(Loc.str("log.error")) ? .red : entry.title.contains(Loc.str("log.skip")) ? .orange : .gray).frame(width: 6, height: 6)
                                Text(entry.timestamp, style: .time).font(.system(size: 10)).foregroundColor(.secondary)
                                Text(entry.title).font(.system(size: 10, weight: .medium))
                            }
                            Text(entry.message).font(.system(size: 10, design: .monospaced)).lineLimit(3)
                        }.padding(.horizontal, 12).padding(.vertical, 5)
                        Divider().padding(.leading, 12)
                    }
                }.padding(.vertical, 4)
            }.background(Color(nsColor: .textBackgroundColor))
        }
    }
    
    // MARK: - Helpers
    
    private func loadSettings() {
        apiKey = DeepSeekClient.shared.apiKey; systemPrompt = DeepSeekClient.shared.systemPrompt
        pollingInterval = engine.pollingInterval; minReplyDelay = engine.minReplyDelay; maxReplyDelay = engine.maxReplyDelay
        skipProbability = engine.skipProbability; workHoursEnabled = engine.workHoursEnabled
        workHoursStart = Double(engine.workHoursStart ?? 9); workHoursEnd = Double(engine.workHoursEnd ?? 23)
    }
    private func saveSettings() {
        DeepSeekClient.shared.apiKey = apiKey; DeepSeekClient.shared.systemPrompt = systemPrompt
        engine.pollingInterval = pollingInterval; engine.minReplyDelay = minReplyDelay; engine.maxReplyDelay = maxReplyDelay
        engine.skipProbability = skipProbability; engine.workHoursEnabled = workHoursEnabled
        engine.workHoursStart = Int(workHoursStart); engine.workHoursEnd = Int(workHoursEnd)
    }
    private func saveContactPrompts() { DeepSeekClient.shared.contactPrompts = contactPrompts }
}

struct StatusBadge: View {
    let isRunning: Bool; let text: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(isRunning ? .green : .secondary.opacity(0.4)).frame(width: 7, height: 7)
            Text(text).font(.caption).foregroundColor(.secondary).lineLimit(1)
        }
    }
}

// MARK: - Pasteable Secure Field

class SecureTextField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            let c = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if ["a", "c", "v", "x"].contains(c) { return super.performKeyEquivalent(with: event) }
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct PasteableSecureField: NSViewRepresentable {
    let placeholder: String; @Binding var text: String
    init(_ placeholder: String, text: Binding<String>) { self.placeholder = placeholder; self._text = text }
    func makeNSView(context: Context) -> SecureTextField {
        let f = SecureTextField(); f.placeholderString = placeholder; f.delegate = context.coordinator
        f.isBordered = true; f.bezelStyle = .roundedBezel; f.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        return f
    }
    func updateNSView(_ nsView: SecureTextField, context: Context) { if nsView.stringValue != text { nsView.stringValue = text } }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: PasteableSecureField; init(_ parent: PasteableSecureField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) { if let f = obj.object as? NSTextField { parent.text = f.stringValue } }
    }
}
