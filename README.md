<p align="center">
  <img src="assets/icon.png" width="128" height="128" alt="AgentGlance icon">
</p>

<h1 align="center">AgentGlance</h1>

<p align="center">
  A macOS overlay for monitoring AI coding agents in real time.<br>
  See live status, approve tool use, answer questions, review plans, and jump to the right terminal tab.
</p>

<p align="center">
  <img src="assets/demo.gif" alt="demo" width="500">
</p>

## What it does

- **Live session status** in a floating overlay (green = working, yellow = needs approval, red = finished)
- **Approve or deny** tool use requests directly from the overlay — no terminal switching
- **"Always Allow"** to add permanent permission rules for trusted commands
- **Answer questions** inline when your agent asks via AskUserQuestion
- **Review plans** with rendered markdown preview, expandable to read the full plan
- **Clickable URLs** for WebFetch and WebSearch — see what your agent is browsing
- **Keyboard navigation** — configurable global hotkey opens the overlay, then navigate with arrow keys or number keys
- **Jump to the right terminal tab** with one click (Ghostty, Terminal.app, iTerm2, Kitty)
- **Open project folder** in Finder from any session row
- **Multi-monitor support** — pin to a specific screen or follow your cursor
- **Notch-aware** — automatically positions below the hardware notch on MacBook Pro
- **Draggable pill** — reposition anywhere, snaps back to center
- **Pin mode** — keep the overlay expanded while you work
- **Liquid Glass** translucent mode with adjustable frost
- **Dark / Light / System** appearance
- **Prevent sleep** while your agent is working
- **Customizable** font size, expanded width, and appearance

Currently supports **Claude Code**. Support for **Codex CLI** and **Gemini CLI** is planned.

## Requirements

- macOS 14.0+ (Sonoma)
- Apple Silicon
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI

## Setup

### 1. Build and run

```bash
git clone https://github.com/hezi/AgentGlance.git
cd AgentGlance
open AgentGlance.xcodeproj
# Build and run (Cmd+R) in Xcode
```

Or build from the command line:

```bash
xcodebuild -project AgentGlance.xcodeproj -scheme AgentGlance -configuration Release build
```

### 2. Add hooks to Claude Code

Add the following to `~/.claude/settings.json` (or use the built-in **Setup Hooks** button — shown automatically on first launch):

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s --connect-timeout 1 -X POST -H 'Content-Type: application/json' -d @- http://localhost:7483/hook/UserPromptSubmit || true"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s --connect-timeout 1 -X POST -H 'Content-Type: application/json' -d @- http://localhost:7483/hook/SessionStart || true"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s --connect-timeout 1 -X POST -H 'Content-Type: application/json' -d @- http://localhost:7483/hook/SessionEnd || true"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s --connect-timeout 1 -X POST -H 'Content-Type: application/json' -d @- http://localhost:7483/hook/PreToolUse || true"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s --connect-timeout 1 -X POST -H 'Content-Type: application/json' -d @- http://localhost:7483/hook/PostToolUse || true"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s --connect-timeout 1 -X POST -H 'Content-Type: application/json' -d @- http://localhost:7483/hook/Stop || true"
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s --connect-timeout 1 -X POST -H 'Content-Type: application/json' -d @- http://localhost:7483/hook/Notification || true"
          }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "curl -s --max-time 120 -X POST -H 'Content-Type: application/json' -d @- http://localhost:7483/hook/PermissionRequest || true",
            "timeout": 120
          }
        ]
      }
    ]
  }
}
```

All hooks use `|| true` so they fail silently when AgentGlance isn't running.

## Features

### Floating Overlay

A floating pill shows the current state of your coding agent sessions:

| State | Color | Meaning |
|-------|-------|---------|
| Working | Green spinner | Agent is running tools |
| Awaiting Approval | Yellow pulse | Agent needs permission to proceed |
| Ready | Red pulse | Agent finished, waiting for your next prompt |
| Complete | Green check | Session ended |
| Idle | Gray dot | No activity |

Hover to expand and see all active sessions. Click any session to jump to its terminal tab. Each session row has buttons to open the terminal or the project folder in Finder.

When expanded, the header shows a **pin** button (keeps the overlay open) and a **settings** button.

The overlay automatically positions below the hardware notch on MacBook Pro models.

### Permission Control

When your agent needs approval to run a tool, the overlay shows the tool name and command/file path with action buttons:

- **Allow** — approve this one request
- **Always** — approve and add a permanent rule to project settings (never ask again for this command)
- **Deny** — reject the request
- **Skip** — dismiss and let the normal CLI prompt handle it

Multiple pending approvals are queued — resolve them one by one, or enable "Show all queued approvals" in settings to see them all at once.

### Question Answering

When your agent asks a question via `AskUserQuestion`, the overlay displays the question with selectable option chips. Pick your answer directly from the overlay without switching to the terminal.

### Plan Review

When your agent proposes an implementation plan (`ExitPlanMode`), the overlay shows a blue-themed card with:
- A **rendered markdown preview** of the plan (headings, bullet points, inline formatting)
- **"Show full plan"** button to expand and read the entire plan in a scrollable view
- **Approve** / **Reject** buttons
- **Open** button to view the full plan file in your editor

### Clickable URLs & Search Queries

When your agent uses `WebFetch`, the URL is displayed as a clickable blue link. When it uses `WebSearch`, the search query links to a Google search. Both work in the approval card and in the session row while the tool is running.

### Keyboard Navigation

Press the global hotkey (default **⌘⇧C**) to expand the overlay and enter keyboard navigation mode. Two modes are available (configurable in Settings):

**Arrow Keys mode** (default):
- `↑`/`↓` — move between session rows
- `←`/`→` — cycle through actions for the focused row
- `Return` — execute the focused action
- `Escape` — go back one level, then collapse

**Number Keys mode:**
- `1-9` — select a row by number (badges shown)
- `1-9` again — execute an action by number
- `Escape` — go back one level, then collapse

Actions include Allow/Deny/Skip for approvals, answer options for questions, Approve/Reject for plans, and Terminal/Folder for regular sessions.

### Terminal Navigation

Click any session row to activate the correct terminal tab. The app detects which terminal owns each process by walking the parent PID chain.

| Terminal | Method |
|----------|--------|
| Ghostty | AppleScript — matches by TTY, tab name, and working directory |
| Terminal.app | AppleScript — matches by TTY device |
| iTerm2 | AppleScript — matches by TTY device |
| Kitty | `kitten @ focus-window --match pid:<pid>` |

Requires Automation permission (grant via Settings > Permissions or on first launch).

### Draggable Pill

Drag the pill to reposition it anywhere on screen. Release near the default position (top center) and it snaps back with an animation. Custom position is persisted across launches. Use **Reset Position** in Settings to restore the default.

### Multi-Monitor

Choose which display the overlay appears on:

- **Main Screen** — always on the primary display (default)
- **Follow Cursor** — moves to whichever screen your cursor is on
- **Specific Screen** — pick a connected display from the list

### Sleep Prevention

Toggle in settings to prevent macOS from sleeping while any coding agent session is actively working.

### Process Detection

On launch, AgentGlance reads `~/.claude/sessions/*.json` to detect already-running Claude Code sessions. No need to restart your sessions — they appear immediately with correct names and elapsed times.

### First Launch

On first launch, AgentGlance:
- Opens the **onboarding window** with hooks JSON to copy into your Claude Code settings
- Requests **notification permission** for session alerts
- Requests **automation permission** for terminal tab control

## Settings

### General
| Setting | Default | Description |
|---------|---------|-------------|
| Display | Main Screen | Which monitor shows the overlay (Main / Follow Cursor / Specific) |
| Prevent sleep | On | Block macOS sleep while agent is working |
| Play sound | On | Alert sound on state changes |
| Auto-expand on approval | Off | Auto-expand overlay when approval needed |
| Show all queued approvals | Off | Show all pending approvals at once |
| Global hotkey | ⌘⇧C | Configurable shortcut to open overlay with keyboard nav |
| Keyboard navigation | Arrow Keys | Navigation mode: Arrow Keys or Number Keys |
| Launch at login | Off | Start AgentGlance when you log in |

### Appearance
| Setting | Default | Description |
|---------|---------|-------------|
| Theme | System | Dark, Light, or follow system appearance |
| Show status text | On | Display text in the collapsed pill |
| Fit width to text | Off | Shrink-wrap the collapsed pill to its label |
| Liquid Glass | Off | Translucent glass background |
| Frost | 0.3 | Glass opacity (only with Liquid Glass) |
| Expanded width | 340px | Width of the overlay when expanded |
| Font size | M | Scale all text (System, XS, S, M, L, XL, XXL) |

### Server
| Setting | Default | Description |
|---------|---------|-------------|
| Port | 7483 | Local HTTP server port for hooks |

## Architecture

```
AgentGlance/
  App/
    AgentGlanceApp.swift       # @main, MenuBarExtra entry point
    AppState.swift              # Central coordinator, window management, hotkey, keyboard nav
  Models/
    Session.swift               # Session state machine and model
    HookEvent.swift             # Hook payload types and JSON decoding
  Server/
    HookServer.swift            # NWListener HTTP server, permission decision handling
    HTTPParser.swift            # Minimal HTTP/1.1 request parser
  Services/
    SessionManager.swift        # Session lifecycle, state transitions, tool summary extraction
    ProcessScanner.swift        # Detect running sessions from ~/.claude/sessions/
    TerminalActivator.swift     # AppleScript/CLI terminal tab activation
    SleepManager.swift          # IOKit sleep assertion
    NotificationManager.swift   # UNUserNotificationCenter alerts
  Views/
    NotchOverlay.swift          # Floating overlay with expand/collapse animations
    MenuBarView.swift           # Menu bar dropdown with session list and controls
    SettingsView.swift          # Settings window (General, Appearance, Server, Permissions, Debug)
    OnboardingView.swift        # Hooks setup guide with copy-to-clipboard
    AppIconViews.swift          # SwiftUI views used to generate the app icon
  Utilities/
    NotchWindow.swift           # NSPanel with drag, notch-aware positioning, content-sized framing
    Constants.swift             # Default port, UserDefaults keys, font scales, keyboard nav types
```

One dependency: [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) for global hotkey registration (via Carbon, no permissions required).

## License

MIT
