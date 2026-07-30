# WeChat Auto Reply

<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="WeChat Auto Reply App Icon">
</p>

> **macOS only.** Automatically read and reply to WeChat messages using macOS Accessibility API and DeepSeek AI.

## How It Works

1. You open a WeChat chat window manually
2. The app reads incoming messages via macOS Accessibility API
3. DeepSeek generates a natural, human-like reply
4. The reply is typed out **character by character** (with random delays) directly into WeChat — not pasted instantly

This makes replies look natural and reduces the risk of detection.

## Features

- **Human-like typing** — 50-200ms random delay per character, occasional thinking pauses
- **Burst message handling** — intelligently handles multiple messages sent in rapid succession by waiting for the sender to finish
- **Skip probability** — randomly ignore some messages to avoid replying to everything
- **Work hours** — only auto-reply during specified hours
- **Per-contact system prompts** — control tone, style, and behavior of replies globally or individually for different contacts
- **Model language control** — seamlessly force the AI model to reply in a specific language (e.g., Chinese, English)
- **Proactive mode** — let AI send the first message to start a conversation
- **Conversation memory** — keeps context from recent messages (last 20 rounds)

## Requirements

- **macOS 14.0 or later** (Apple Silicon)
- **WeChat.app** (Mac version) running and logged in
- **DeepSeek API key** ([platform.deepseek.com](https://platform.deepseek.com))
- **Accessibility permission** — grant in System Settings → Privacy & Security → Accessibility

## Installation

```bash
# Clone and build
git clone https://github.com/JunxiBao/WeChatAutoReply.git
cd WeChatAutoReply
bash build.sh --install
```

The app will be installed to `/Applications/WeChatAutoReply.app`.

## Usage

1. Launch the app — the settings window opens automatically
2. Paste your DeepSeek API key (click the eye icon to reveal the text field for pasting)
3. Grant accessibility permission when prompted
4. Open WeChat and navigate to the chat you want to auto-reply to
5. Click **Start** to begin monitoring, or **AI Send** to send an opening message

### Buttons

| Button | What it does |
|--------|-------------|
| **Start** | Begin monitoring — replies to new incoming messages |
| **AI Send** | AI sends one proactive message to the current chat |
| **Reset Memory** | Clear conversation history |

### Settings

| Setting | Default | Description |
|---------|---------|-------------|
| Poll interval | 3s | How often to check for new messages |
| Min reply delay | 3s | Minimum wait before replying |
| Max reply delay | 15s | Maximum wait before replying |
| Skip probability | 20% | Chance to randomly skip a message |
| Work hours | Off | Only auto-reply during set hours |
| Model Language | Chinese | Output language setting for the AI model |
| System Prompt | Default | Customize prompt per-contact for varied personalities |

## System Prompt (Recommended)

```
You are a real person replying to a friend on WeChat.
Rules:
- Casual, natural tone with filler words (嗯, 哈, 啦, 吧)
- Occasional typos or abbreviations
- Never say "Hello, how can I help you" or other AI phrases
- Keep replies short, 1-3 sentences
- If you need time to think, say "Let me check" or "One sec"
- Always reply in Chinese
```

## Architecture

```
WeChatAutoReply.app/
├── Sources/
│   ├── main.swift              # App entry point & menu bar
│   ├── WeChatBridge.swift      # Accessibility API bridge
│   ├── DeepSeekClient.swift    # DeepSeek API client
│   ├── AutoReplyEngine.swift   # Core polling & reply logic
│   └── SettingsView.swift      # SwiftUI settings window
├── Resources/
│   ├── Info.plist
│   └── AppIcon.icns
└── build.sh                    # Build script
```

The app uses `CGEventPostToPid` to send keystrokes directly to the WeChat process, so it doesn't require WeChat to be in the foreground.

## Safety & Disclaimer

This app uses **only system-level Accessibility APIs** — no network interception, no code injection, no reverse engineering of WeChat protocols. The app reads what's visible on screen and simulates keyboard input, just like a human would.

However, WeChat's Terms of Service **prohibit automated behavior**. While the app includes anti-detection measures (random delays, skip probability, human-like typing), use at your own risk.

## License

MIT
