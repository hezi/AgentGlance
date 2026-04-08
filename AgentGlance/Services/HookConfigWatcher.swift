import Foundation
import os

private let logger = Logger(subsystem: "app.agentglance", category: "HookConfigWatcher")

/// Watches ~/.claude/settings.json for external modifications and re-injects hooks if removed.
@Observable
@MainActor
final class HookConfigWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var debounceWork: DispatchWorkItem?
    private var repairTimestamps: [Date] = []

    private let maxRepairsPerHour = 5
    private let settingsPath: String
    private let bridgeCommand: String

    private(set) var lastRepairDate: Date?

    init() {
        self.settingsPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
        self.bridgeCommand = "~/.agentglance/bin/agentglance-bridge"
    }

    func startWatching() {
        stopWatching()

        let path = settingsPath
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            logger.info("Cannot watch settings file (not found yet): \(path)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            self?.scheduleCheck()
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 {
                close(fd)
                self?.fd = -1
            }
        }

        self.source = source
        source.resume()
        logger.info("Watching \(path) for hook changes")
    }

    func stopWatching() {
        debounceWork?.cancel()
        source?.cancel()
        source = nil
    }

    // MARK: - Debounced check

    private func scheduleCheck() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.handleFileChange()
            }
        }
        debounceWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func handleFileChange() {
        guard !verifyHooks() else { return }
        logger.info("Hooks missing or damaged in settings.json")

        guard canRepair() else {
            logger.warning("Rate limit reached — skipping hook repair (\(self.repairTimestamps.count) repairs this hour)")
            return
        }

        repairHooks()
    }

    // MARK: - Verification

    /// Returns true if our hooks are present in settings.json
    func verifyClaudeHooks() -> Bool {
        return verifyHooks()
    }

    private func verifyHooks() -> Bool {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        let requiredEvents = HookEventType.allCases.map(\.rawValue)

        for event in requiredEvents {
            guard let eventHooks = hooks[event] as? [[String: Any]] else { return false }
            let hasOurs = eventHooks.contains { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { hook in
                    guard let cmd = hook["command"] as? String else { return false }
                    return cmd.contains("agentglance-bridge") || cmd.contains("agentglance")
                }
            }
            if !hasOurs { return false }
        }

        return true
    }

    // MARK: - Repair

    private func canRepair() -> Bool {
        let oneHourAgo = Date().addingTimeInterval(-3600)
        repairTimestamps.removeAll { $0 < oneHourAgo }
        return repairTimestamps.count < maxRepairsPerHour
    }

    private func repairHooks() {
        let fm = FileManager.default

        // Read current settings (or start fresh)
        var settings: [String: Any]
        if let data = fm.contents(atPath: settingsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        } else {
            settings = [:]
        }

        // Backup before modifying (remove stale backup first)
        let backupPath = settingsPath + ".agentglance-backup"
        try? fm.removeItem(atPath: backupPath)
        try? fm.copyItem(atPath: settingsPath, toPath: backupPath)

        // Merge our hooks into existing hooks (preserve non-AgentGlance hooks)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for event in HookEventType.allCases {
            let eventName = event.rawValue
            let isPermission = eventName == "PermissionRequest"

            var hook: [String: Any] = [
                "type": "command",
                "command": bridgeCommand,
            ]
            if isPermission {
                hook["timeout"] = 120
            }

            let ourEntry: [String: Any] = [
                "matcher": "",
                "hooks": [hook],
            ]

            if var existing = hooks[eventName] as? [[String: Any]] {
                // Remove our old entries, then add fresh one
                existing.removeAll { entry in
                    guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                    return hookList.contains { ($0["command"] as? String)?.contains("agentglance") == true }
                }
                existing.append(ourEntry)
                hooks[eventName] = existing
            } else {
                hooks[eventName] = [ourEntry]
            }
        }

        settings["hooks"] = hooks

        // Write atomically — Data.write with .atomic uses a temp file + rename internally,
        // which is safe even if the destination already exists
        guard let jsonData = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else {
            logger.error("Failed to serialize repaired settings")
            return
        }

        do {
            try jsonData.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
        } catch {
            logger.error("Failed to write repaired settings: \(error.localizedDescription)")
            return
        }

        repairTimestamps.append(Date())
        lastRepairDate = Date()
        logger.info("Hooks repaired in settings.json (repair #\(self.repairTimestamps.count) this hour)")
    }
}
