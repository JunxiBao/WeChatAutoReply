import Foundation

// MARK: - Localization Manager

enum AppLanguage: String, CaseIterable {
    case system = "system"
    case english = "en"
    case chinese = "zh-Hans"
    
    var displayName: String {
        switch self {
        case .system: return "System / 系统"
        case .english: return "English"
        case .chinese: return "中文"
        }
    }
}

class Loc {
    static var language: AppLanguage {
        get {
            if let raw = UserDefaults.standard.string(forKey: "app_language"),
               let lang = AppLanguage(rawValue: raw) {
                return lang
            }
            return .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "app_language")
        }
    }
    
    static var isChinese: Bool {
        switch language {
        case .chinese: return true
        case .english: return false
        case .system:
            let preferred = Bundle.main.preferredLocalizations.first ?? "en"
            return preferred.hasPrefix("zh")
        }
    }
    
    static func str(_ key: String) -> String {
        isChinese ? zh[key, default: key] : en[key, default: key]
    }
    
    // MARK: - English Strings
    static let en: [String: String] = [
        "app.name": "WeChat Auto Reply",
        "status.ready": "Ready",
        "status.running": "Running...",
        "status.stopped": "Stopped",
        "status.checking": "Checking messages...",
        "status.no_new": "No new messages",
        "status.permission": "Grant Accessibility permission",
        "status.wechat_off": "WeChat not running",
        "status.api_key": "Set API Key",
        "status.history": "Ready (loaded %d history)",
        "status.reply": "Replied (%d)",
        "status.sent": "Sent (%d)",
        "status.work_hours": "Outside work hours",
        "status.skip": "Skipped - %@",
        "status.thinking": "AI thinking...",
        "status.generated": "Reply generated (%d chars)",
        "status.countdown": "%d seconds...",
        "status.typing": "Typing...",
        "status.multi_msgs": "Received %d messages",
        "status.failed": "Send failed",
        "status.error": "Error: %@",
        "status.generating": "Generating opener...",
        
        "status.unknown_chat": "Unknown Chat",
        "status.n_msgs": "%d messages",
        "status.msg": "message",
        
        "tab.general": "General",
        "tab.prompt": "Prompt",
        "tab.contacts": "Contacts",
        "tab.logs": "Logs",
        
        "section.api": "DeepSeek API",
        "section.polling": "Polling",
        "section.delay": "Reply Delay",
        "section.behavior": "Behavior",
        "section.status": "Status",
        "section.actions": "Actions",
        "section.hours": "Work Hours",
        
        "label.interval": "Check Interval",
        "label.min_delay": "Min Delay",
        "label.max_delay": "Max Delay",
        "label.skip": "Skip Chance",
        "label.engine": "Engine",
        "label.chat": "Chat",
        "label.replied": "Replied",
        "label.last_check": "Last Check",
        "label.hide_menubar": "Hide Menu Bar Icon",
        "label.limit_hours": "Limit Work Hours",
        "label.from": "From",
        "label.to": "To",
        "label.language": "Language",
        
        "btn.start": "Start",
        "btn.stop": "Stop",
        "btn.ai_send": "AI Send",
        "btn.reset": "Reset Memory",
        "btn.add": "Add",
        "btn.update": "Update",
        "btn.cancel": "Cancel",
        "btn.edit": "Edit",
        "btn.delete": "Delete",
        "btn.default_prompt": "Use Recommended",
        "btn.settings": "Settings...",
        "btn.quit": "Quit",
        
        "menu.status": "Status: %@",
        "menu.running_status": "Status: Running · %d replied",
        "menu.toggle_start": "Start Auto Reply",
        "menu.toggle_stop": "Stop Auto Reply",
        
        "prompt.recommended": "Recommended: casual tone, filler words, avoid AI feel. AI auto-detects language.",
        "prompt.default": """
        You are a real person replying to a friend on WeChat.
        Rules:
        - Casual, natural tone with filler words
        - Occasional typos or abbreviations
        - Never say "Hello, how can I help you" or other AI phrases
        - Keep replies short, 1-3 sentences
        - If you need time to think, say "Let me check" or "One sec"
        """,
        
        "contact.hint": "Set per-contact system prompts. Empty = use global prompt.",
        "contact.name_placeholder": "Contact Name",
        "contact.edit_hint": "Click Edit to modify, Delete to remove.",
        "contact.section_add": "Add Contact Prompt",
        "contact.section_edit": "Edit: %@",
        "contact.section_list": "Configured (%d)",
        
        "alert.permission_title": "Accessibility Permission Needed",
        "alert.permission_body": """
        WeChat Auto Reply needs Accessibility access to read and type messages.
        
        Grant permission in:
        System Settings → Privacy & Security → Accessibility
        Find WeChatAutoReply and toggle it on.
        """,
        "alert.permission_btn": "Open System Settings",
        "alert.permission_later": "Later",
        "alert.wechat_off": "WeChat not running. Please open WeChat and a chat window.",
        "alert.api_key": "Please set your DeepSeek API Key in Settings first.",
        "alert.ok": "OK",
        
        "log.reply": "Reply",
        "log.sent": "Sent",
        "log.skip": "Skip",
        "log.error": "Error",
        "log.received": "Received %@",
    ]
    
    // MARK: - Chinese Strings
    static let zh: [String: String] = [
        "app.name": "微信自动回复",
        "status.ready": "就绪",
        "status.running": "运行中...",
        "status.stopped": "已停止",
        "status.checking": "检查消息中...",
        "status.no_new": "无新消息",
        "status.permission": "需要辅助功能权限",
        "status.wechat_off": "微信未运行",
        "status.api_key": "请配置 API Key",
        "status.history": "就绪 (已加载 %d 条历史)",
        "status.reply": "已回复 (%d 条)",
        "status.sent": "已发送 (%d 条)",
        "status.work_hours": "工作时间外",
        "status.skip": "跳过 - %@",
        "status.thinking": "AI 思考中...",
        "status.generated": "已生成回复 (%d字)",
        "status.countdown": "%d秒后回复...",
        "status.typing": "正在输入...",
        "status.multi_msgs": "收到 %d 条新消息",
        "status.failed": "发送失败",
        "status.error": "错误: %@",
        "status.generating": "生成开场白...",
        
        "status.unknown_chat": "未知聊天",
        "status.n_msgs": "%d条消息",
        "status.msg": "消息",
        
        "tab.general": "通用",
        "tab.prompt": "提示词",
        "tab.contacts": "联系人",
        "tab.logs": "日志",
        
        "section.api": "DeepSeek API",
        "section.polling": "轮询",
        "section.delay": "回复延迟",
        "section.behavior": "行为",
        "section.status": "状态",
        "section.actions": "操作",
        "section.hours": "工作时间",
        
        "label.interval": "检查间隔",
        "label.min_delay": "最小延迟",
        "label.max_delay": "最大延迟",
        "label.skip": "跳过概率",
        "label.engine": "引擎",
        "label.chat": "聊天对象",
        "label.replied": "已回复",
        "label.last_check": "上次检查",
        "label.hide_menubar": "隐藏菜单栏图标",
        "label.limit_hours": "限制工作时间",
        "label.from": "从",
        "label.to": "到",
        "label.language": "语言",
        
        "btn.start": "启动",
        "btn.stop": "停止",
        "btn.ai_send": "AI 发消息",
        "btn.reset": "重置记忆",
        "btn.add": "添加",
        "btn.update": "更新",
        "btn.cancel": "取消",
        "btn.edit": "编辑",
        "btn.delete": "删除",
        "btn.default_prompt": "使用推荐提示词",
        "btn.settings": "设置...",
        "btn.quit": "退出",
        
        "menu.status": "状态: %@",
        "menu.running_status": "状态: 运行中 · 已回复 %d 条",
        "menu.toggle_start": "启动自动回复",
        "menu.toggle_stop": "停止自动回复",
        
        "prompt.recommended": "推荐设置：口语化、带语气词、避免 AI 感。由 AI 自行判断语言。",
        "prompt.default": """
        你是一个真实的人，正在帮朋友回复微信消息。
        回复规则：
        - 口语化、随意、带适当语气词（嗯、哈、啦、吧）
        - 偶尔有错别字或简写（比如「好的」写成「好滴」）
        - 绝不说「你好」「很高兴为你服务」这种AI用语
        - 回复简短，通常1-3句话
        - 如果问题需要思考，可以先说「我看看」「稍等哈」
        """,
        
        "contact.hint": "为不同联系人设置专属的系统提示词。留空则使用全局提示词。",
        "contact.name_placeholder": "联系人名称",
        "contact.edit_hint": "点击「编辑」修改已有联系人的提示词，点击「删除」移除",
        "contact.section_add": "新增联系人提示词",
        "contact.section_edit": "编辑: %@",
        "contact.section_list": "已配置 (%d 个)",
        
        "alert.permission_title": "需要辅助功能权限",
        "alert.permission_body": """
        微信自动回复需要辅助功能权限才能读取消息和输入回复。
        
        请打开系统设置授予权限：
        系统设置 → 隐私与安全性 → 辅助功能
        找到 WeChatAutoReply 并打开开关
        """,
        "alert.permission_btn": "打开系统设置",
        "alert.permission_later": "稍后",
        "alert.wechat_off": "微信未运行，请先打开微信并打开一个聊天窗口。",
        "alert.api_key": "请在设置中填入 DeepSeek API Key。",
        "alert.ok": "确定",
        
        "log.reply": "回复",
        "log.sent": "主动发送",
        "log.skip": "跳过",
        "log.error": "错误",
        "log.received": "收到%@",
    ]
    
    // MARK: - Convenience
    
    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: str(key), arguments: args)
    }
}
