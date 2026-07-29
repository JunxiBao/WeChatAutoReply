import SwiftUI

// MARK: - Settings Window

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
    
    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("通用", systemImage: "gearshape") }
            promptTab
                .tabItem { Label("提示词", systemImage: "text.quote") }
            contactPromptTab
                .tabItem { Label("联系人", systemImage: "person.text.rectangle") }
            logTab
                .tabItem { Label("日志", systemImage: "list.bullet.rectangle") }
        }
        .frame(minWidth: 440, idealWidth: 480, minHeight: 380, idealHeight: 440)
        .onAppear { loadSettings() }
    }
    
    // MARK: - General Tab
    
    var generalTab: some View {
        Form {
            // ── API ──
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    PasteableSecureField("sk-...", text: $apiKey)
                        .frame(height: 22)
                        .onChange(of: apiKey) { _, v in DeepSeekClient.shared.apiKey = v }
                    
                    Label("从 platform.deepseek.com 获取", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("DeepSeek API").fontWeight(.semibold)
            }
            
            // ── 轮询 ──
            Section {
                LabeledContent("检查间隔") {
                    HStack(spacing: 6) {
                        Slider(value: $pollingInterval, in: 1...10, step: 0.5)
                            .frame(width: 90)
                        Text(String(format: "%.1f 秒", pollingInterval))
                            .font(.caption).monospacedDigit()
                            .foregroundColor(.secondary).frame(width: 42, alignment: .trailing)
                    }
                }
                .onChange(of: pollingInterval) { _, v in engine.pollingInterval = v }
            } header: {
                Text("轮询").fontWeight(.semibold)
            }
            
            // ── 回复延迟 ──
            Section {
                LabeledContent("最小延迟") {
                    HStack(spacing: 6) {
                        Slider(value: $minReplyDelay, in: 0...30, step: 0.5)
                            .frame(width: 90)
                        Text(String(format: "%.0f 秒", minReplyDelay))
                            .font(.caption).monospacedDigit()
                            .foregroundColor(.secondary).frame(width: 35, alignment: .trailing)
                    }
                }
                .onChange(of: minReplyDelay) { _, v in engine.minReplyDelay = v }
                
                LabeledContent("最大延迟") {
                    HStack(spacing: 6) {
                        Slider(value: $maxReplyDelay, in: 1...60, step: 0.5)
                            .frame(width: 90)
                        Text(String(format: "%.0f 秒", maxReplyDelay))
                            .font(.caption).monospacedDigit()
                            .foregroundColor(.secondary).frame(width: 35, alignment: .trailing)
                    }
                }
                .onChange(of: maxReplyDelay) { _, v in engine.maxReplyDelay = v }
            } header: {
                Text("回复延迟").fontWeight(.semibold)
            }
            
            // ── 行为 ──
            Section {
                Toggle("隐藏菜单栏图标", isOn: $hideMenuBar)
                    .onChange(of: hideMenuBar) { _, v in
                        if let delegate = NSApp.delegate as? AppDelegate {
                            delegate.hideMenuBarIcon = v
                        }
                    }
                
                LabeledContent("跳过概率") {
                    HStack(spacing: 6) {
                        Slider(value: $skipProbability, in: 0...0.8, step: 0.05)
                            .frame(width: 90)
                        Text(String(format: "%.0f%%", skipProbability * 100))
                            .font(.caption).monospacedDigit()
                            .foregroundColor(.secondary).frame(width: 34, alignment: .trailing)
                    }
                }
                .onChange(of: skipProbability) { _, v in engine.skipProbability = v }
                
                Toggle("限制工作时间", isOn: $workHoursEnabled)
                    .onChange(of: workHoursEnabled) { _, v in engine.workHoursEnabled = v }
                
                if workHoursEnabled {
                    HStack {
                        Text("从").font(.caption).foregroundColor(.secondary)
                        Stepper("\(Int(workHoursStart)):00", value: $workHoursStart, in: 0...23)
                            .font(.caption)
                            .onChange(of: workHoursStart) { _, v in engine.workHoursStart = Int(v) }
                        Text("到").font(.caption).foregroundColor(.secondary).padding(.leading, 4)
                        Stepper("\(Int(workHoursEnd)):00", value: $workHoursEnd, in: 1...24)
                            .font(.caption)
                            .onChange(of: workHoursEnd) { _, v in engine.workHoursEnd = Int(v) }
                    }
                }
            } header: {
                Text("行为").fontWeight(.semibold)
            }
            
            // ── 状态 ──
            Section {
                LabeledContent("引擎") {
                    StatusBadge(isRunning: engine.isRunning, text: engine.statusMessage)
                }
                if let chat = engine.currentChatName {
                    LabeledContent("聊天对象") {
                        Text(chat).foregroundColor(.secondary).font(.caption)
                    }
                }
                LabeledContent("已回复") {
                    Text("\(engine.processedCount) 条").foregroundColor(.secondary).font(.caption)
                }
                if let last = engine.lastCheckTime {
                    LabeledContent("上次检查") {
                        Text(last, style: .time).foregroundColor(.secondary).font(.caption)
                    }
                }
            } header: {
                Text("状态").fontWeight(.semibold)
            }
            
            // ── 操作 ──
            Section {
                HStack(spacing: 8) {
                    Button(engine.isRunning ? "停止" : "启动") {
                        saveSettings()
                        engine.isRunning ? engine.stop() : engine.start()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                    
                    if engine.isRunning {
                        Button {
                            Task { await engine.sendFirstMessage() }
                        } label: {
                            HStack(spacing: 3) {
                                if engine.isSendingFirstMessage {
                                    ProgressView().scaleEffect(0.55).frame(width: 10, height: 10)
                                }
                                Text("AI 发消息")
                            }
                        }
                        .disabled(engine.isSendingFirstMessage)
                        .help("让 AI 主动给当前微信聊天发一条消息")
                        
                        Button("重置记忆") { engine.resetConversationHistory() }
                            .controlSize(.regular)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
    
    // MARK: - Prompt Tab
    
    var promptTab: some View {
        Form {
            Section {
                TextEditor(text: $systemPrompt)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)
                    .onChange(of: systemPrompt) { _, v in DeepSeekClient.shared.systemPrompt = v }
            } header: {
                Text("系统提示词").fontWeight(.semibold)
            }
            
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("推荐设置：口语化、带语气词、避免 AI 感。由 AI 自行判断语言。")
                        .font(.caption).foregroundColor(.secondary)
                    
                    Button("使用推荐提示词") {
                        systemPrompt = """
                        你是一个真实的人，正在帮朋友回复微信消息。
                        回复规则：
                        - 口语化、随意、带适当语气词（嗯、哈、啦、吧）
                        - 偶尔有错别字或简写（比如「好的」写成「好滴」）
                        - 绝不说「你好」「很高兴为你服务」这种AI用语
                        - 回复简短，通常1-3句话
                        - 如果问题需要思考，可以先说「我看看」「稍等哈」
                        """
                        DeepSeekClient.shared.systemPrompt = systemPrompt
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
    
    // MARK: - Contact Prompt Tab
    
    @State private var contactPrompts: [String: String] = [:]
    @State private var newContactName: String = ""
    @State private var newContactPrompt: String = ""
    @State private var editingContactName: String? = nil
    
    var contactPromptTab: some View {
        Form {
            Section {
                Text("为不同联系人设置专属的系统提示词。留空则使用全局提示词。")
                    .font(.caption).foregroundColor(.secondary)
            }
            
            Section {
                HStack {
                    TextField("联系人名称", text: $newContactName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(editingContactName != nil)
                    Button(editingContactName != nil ? "更新" : "添加") {
                        let name = (editingContactName ?? newContactName).trimmingCharacters(in: .whitespaces)
                        let prompt = newContactPrompt.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty, !prompt.isEmpty else { return }
                        contactPrompts[name] = prompt
                        saveContactPrompts()
                        newContactName = ""
                        newContactPrompt = ""
                        editingContactName = nil
                    }
                    .disabled(newContactPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
                    if editingContactName != nil {
                        Button("取消") {
                            newContactName = ""
                            newContactPrompt = ""
                            editingContactName = nil
                        }
                    }
                }
                TextEditor(text: $newContactPrompt)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 60)
            } header: {
                Text(editingContactName != nil ? "编辑: \(editingContactName!)" : "新增联系人提示词").fontWeight(.semibold)
            }
            
            if !contactPrompts.isEmpty {
                Section {
                    ForEach(Array(contactPrompts.keys.sorted()), id: \.self) { name in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(name).fontWeight(.medium)
                                Spacer()
                                Button("编辑") {
                                    newContactName = name
                                    newContactPrompt = contactPrompts[name] ?? ""
                                    editingContactName = name
                                }
                                Button("删除") {
                                    contactPrompts.removeValue(forKey: name)
                                    saveContactPrompts()
                                    if editingContactName == name {
                                        newContactName = ""
                                        newContactPrompt = ""
                                        editingContactName = nil
                                    }
                                }
                                .foregroundColor(.red)
                            }
                            Text(contactPrompts[name] ?? "")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("已配置 (\(contactPrompts.count) 个)").fontWeight(.semibold)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            contactPrompts = DeepSeekClient.shared.contactPrompts
            // Pre-fill with current WeChat chat contact
            if let name = engine.currentChatName, !name.isEmpty {
                newContactName = name
            } else if let name = WeChatBridge.shared.getCurrentChatName(), !name.isEmpty {
                newContactName = name
            }
        }
    }
    
    private func saveContactPrompts() {
        DeepSeekClient.shared.contactPrompts = contactPrompts
    }
    
    // MARK: - Log Tab
    
    var logTab: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(AppLogger.shared.getRecentEntries()) { entry in
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(entry.title.contains("回复") ? Color.green :
                                              entry.title.contains("错误") ? Color.red :
                                              entry.title.contains("跳过") ? Color.orange : Color.gray)
                                        .frame(width: 6, height: 6)
                                    Text(entry.timestamp, style: .time)
                                        .font(.system(size: 10)).foregroundColor(.secondary)
                                    Text(entry.title)
                                        .font(.system(size: 10, weight: .medium))
                                }
                                Text(entry.message)
                                    .font(.system(size: 10, design: .monospaced))
                                    .lineLimit(3)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            Divider().padding(.leading, 12)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
    
    // MARK: - Helpers
    
    private func loadSettings() {
        apiKey = DeepSeekClient.shared.apiKey
        systemPrompt = DeepSeekClient.shared.systemPrompt
        pollingInterval = engine.pollingInterval
        minReplyDelay = engine.minReplyDelay
        maxReplyDelay = engine.maxReplyDelay
        skipProbability = engine.skipProbability
        workHoursEnabled = engine.workHoursEnabled
        workHoursStart = Double(engine.workHoursStart ?? 9)
        workHoursEnd = Double(engine.workHoursEnd ?? 23)
    }
    
    private func saveSettings() {
        DeepSeekClient.shared.apiKey = apiKey
        DeepSeekClient.shared.systemPrompt = systemPrompt
        engine.pollingInterval = pollingInterval
        engine.minReplyDelay = minReplyDelay
        engine.maxReplyDelay = maxReplyDelay
        engine.skipProbability = skipProbability
        engine.workHoursEnabled = workHoursEnabled
        engine.workHoursStart = Int(workHoursStart)
        engine.workHoursEnd = Int(workHoursEnd)
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let isRunning: Bool
    let text: String
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isRunning ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Pasteable Secure Field (Cmd+V, Cmd+A, Cmd+C all work)

class SecureTextField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Let AppKit handle all standard edit commands (Cmd+A, Cmd+C, Cmd+V, Cmd+X)
        if event.modifierFlags.contains(.command) {
            let char = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if ["a", "c", "v", "x"].contains(char) {
                return super.performKeyEquivalent(with: event)
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct PasteableSecureField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    
    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }
    
    func makeNSView(context: Context) -> SecureTextField {
        let field = SecureTextField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        return field
    }
    
    func updateNSView(_ nsView: SecureTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: PasteableSecureField
        init(_ parent: PasteableSecureField) { self.parent = parent }
        
        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField {
                parent.text = field.stringValue
            }
        }
    }
}
