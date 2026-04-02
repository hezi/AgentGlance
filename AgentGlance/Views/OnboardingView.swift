import SwiftUI

struct OnboardingView: View {
    @Bindable var appState: AppState
    @State private var copied = false
    @State private var hooksDetected = false
    @State private var checking = false
    @AppStorage(Constants.UserDefaultsKeys.port) private var port: Int = Int(Constants.defaultPort)

    private static let bridgeCommand = "~/.agentglance/bin/agentglance-bridge"

    private var hooksJSON: String {
        let cmd = Self.bridgeCommand
        return """
        {
          "hooks": {
            "UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command", "command": "\(cmd)"}]}],
            "SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "\(cmd)"}]}],
            "SessionEnd": [{"matcher": "", "hooks": [{"type": "command", "command": "\(cmd)"}]}],
            "PreToolUse": [{"matcher": "", "hooks": [{"type": "command", "command": "\(cmd)"}]}],
            "PostToolUse": [{"matcher": "", "hooks": [{"type": "command", "command": "\(cmd)"}]}],
            "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "\(cmd)"}]}],
            "Notification": [{"matcher": "", "hooks": [{"type": "command", "command": "\(cmd)"}]}],
            "PermissionRequest": [{"matcher": "", "hooks": [{"type": "command", "command": "\(cmd)", "timeout": 120}]}]
          }
        }
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Setup Claude Code Hooks")
                        .font(.title2.bold())
                    Text("Add the following hooks to your Claude Code settings")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // Instructions
            VStack(alignment: .leading, spacing: 8) {
                Label("Open your settings file:", systemImage: "1.circle.fill")
                    .font(.subheadline.bold())

                HStack {
                    Text("~/.claude/settings.json")
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))

                    Button("Open in Finder") {
                        openSettingsFile()
                    }
                    .font(.subheadline)
                }

                Label("Add or merge these hooks into your settings:", systemImage: "2.circle.fill")
                    .font(.subheadline.bold())
                    .padding(.top, 4)
            }

            // JSON Block
            ScrollView {
                Text(hooksJSON)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 200)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))

            // Actions
            HStack {
                Button(action: copyToClipboard) {
                    Label(copied ? "Copied!" : "Copy to Clipboard",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .tint(copied ? .green : .accentColor)

                Button(action: checkSettings) {
                    Label(
                        checking ? "Checking..." :
                            (hooksDetected ? "Hooks Detected" : "Verify Settings"),
                        systemImage: hooksDetected ? "checkmark.circle.fill" : "magnifyingglass"
                    )
                }
                .buttonStyle(.bordered)
                .tint(hooksDetected ? .green : nil)

                Spacer()

                Button("Done") {
                    UserDefaults.standard.set(true, forKey: Constants.UserDefaultsKeys.hasCompletedOnboarding)
                    appState.dismissOnboarding()
                }
                .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 560, height: 480)
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hooksJSON, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }

    private func checkSettings() {
        checking = true
        DispatchQueue.global().async {
            let settingsPath = NSString("~/.claude/settings.json").expandingTildeInPath
            let exists = FileManager.default.fileExists(atPath: settingsPath)
            var found = false
            if exists, let data = FileManager.default.contents(atPath: settingsPath),
               let content = String(data: data, encoding: .utf8) {
                found = content.contains("localhost:\(port)/hook")
            }
            DispatchQueue.main.async {
                hooksDetected = found
                checking = false
            }
        }
    }

    private func openSettingsFile() {
        let settingsPath = NSString("~/.claude/settings.json").expandingTildeInPath
        let url = URL(fileURLWithPath: settingsPath)

        // Create file if it doesn't exist
        if !FileManager.default.fileExists(atPath: settingsPath) {
            let dir = (settingsPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? "{}".write(toFile: settingsPath, atomically: true, encoding: .utf8)
        }

        NSWorkspace.shared.open(url)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Onboarding") {
    OnboardingView(appState: AppState())
}
#endif
