import Foundation
import AppKit
import os

private let logger = Logger(subsystem: "app.agentglance", category: "ProcessScanner")

struct ClaudeSessionInfo: Codable {
    let pid: Int
    let sessionId: String
    let cwd: String
    let startedAt: Int64    // epoch ms
    let kind: String?
    let entrypoint: String?
    let name: String?
}

enum ProcessScanner {
    private static let sessionsDir = NSString("~/.claude/sessions").expandingTildeInPath

    private static let knownTerminals: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty",
    ]

    /// Scan ~/.claude/sessions/*.json for active Claude Code sessions
    static func detectRunningSessions() -> [ClaudeSessionInfo] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else {
            logger.info("No sessions directory found at \(sessionsDir)")
            return []
        }

        var activeSessions: [ClaudeSessionInfo] = []

        for file in files where file.hasSuffix(".json") {
            let path = (sessionsDir as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: path) else { continue }

            // Claude Code session files can be truncated (trailing comma, no closing brace)
            // due to fixed-size pre-allocated writes. Try to repair before parsing.
            let parseData = repairTruncatedJSON(data) ?? data

            do {
                let info = try JSONDecoder().decode(ClaudeSessionInfo.self, from: parseData)

                if isProcessRunning(pid: info.pid) {
                    activeSessions.append(info)
                    logger.info("Detected running session: \(info.name ?? info.sessionId) (pid \(info.pid))")
                }
            } catch {
                logger.warning("Failed to parse session file \(file): \(error.localizedDescription)")
            }
        }

        return activeSessions
    }

    // MARK: - Terminal Detection

    /// Get the TTY device for a process (e.g. "ttys003")
    static func getTTY(pid: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "tty="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty, output != "??" else {
            return nil
        }

        // ps returns e.g. "s003" — normalize to full device path component "ttys003"
        if output.hasPrefix("s") {
            return "tty" + output
        }
        return output
    }

    /// Find the terminal app that owns a given process by walking parent PIDs
    static func getTerminalApp(pid: Int) -> String? {
        var currentPID = pid

        // Walk up to 20 levels (more than enough to find the terminal)
        for _ in 0..<20 {
            guard let parentPID = getParentPID(of: currentPID), parentPID > 1 else {
                break
            }

            // Check if this parent is a known terminal app
            if let app = NSRunningApplication(processIdentifier: pid_t(parentPID)),
               let bundleId = app.bundleIdentifier,
               knownTerminals.contains(bundleId) {
                logger.info("Found terminal \(bundleId) for pid \(pid)")
                return bundleId
            }

            currentPID = parentPID
        }

        // Fallback: check all running terminal apps — if exactly one is running, use it
        let runningTerminals = NSWorkspace.shared.runningApplications.filter {
            guard let bid = $0.bundleIdentifier else { return false }
            return knownTerminals.contains(bid)
        }

        if runningTerminals.count == 1, let bid = runningTerminals.first?.bundleIdentifier {
            logger.info("Single terminal running: \(bid), assuming it owns pid \(pid)")
            return bid
        }

        return nil
    }

    private static func getParentPID(of pid: Int) -> Int? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]

        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }

        let ppid = Int(info.kp_eproc.e_ppid)
        return ppid > 0 ? ppid : nil
    }

    private static func isProcessRunning(pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0
    }

    // MARK: - JSONL Title Extraction

    private static let projectsDir = NSString("~/.claude/projects").expandingTildeInPath

    /// Read the last `custom-title` from a session's JSONL transcript.
    /// Path: ~/.claude/projects/<cwd-encoded>/<sessionId>.jsonl
    /// Reads from the end of the file to find the most recent title efficiently.
    static func readTranscriptTitle(sessionId: String, cwd: String) -> String? {
        let encodedCwd = cwd.replacingOccurrences(of: "/", with: "-")
        let jsonlPath = (projectsDir as NSString)
            .appendingPathComponent(encodedCwd)
            .appending("/\(sessionId).jsonl")

        guard let fileHandle = FileHandle(forReadingAtPath: jsonlPath) else { return nil }
        defer { fileHandle.closeFile() }

        // Read from the end in chunks to find the last custom-title line
        let fileSize = fileHandle.seekToEndOfFile()
        guard fileSize > 0 else { return nil }

        let chunkSize: UInt64 = 8192
        var lastTitle: String?
        var offset = fileSize

        // For small files, just read the whole thing
        if fileSize <= chunkSize * 4 {
            fileHandle.seek(toFileOffset: 0)
            let data = fileHandle.readDataToEndOfFile()
            if let content = String(data: data, encoding: .utf8) {
                for line in content.components(separatedBy: .newlines).reversed() {
                    if let title = extractCustomTitle(from: line) {
                        return title
                    }
                }
            }
            return nil
        }

        // For large files, read backwards in chunks
        while offset > 0 {
            let readSize = min(chunkSize, offset)
            offset -= readSize
            fileHandle.seek(toFileOffset: offset)
            let data = fileHandle.readData(ofLength: Int(readSize))
            guard let chunk = String(data: data, encoding: .utf8) else { continue }

            for line in chunk.components(separatedBy: .newlines).reversed() {
                if let title = extractCustomTitle(from: line) {
                    return title
                }
            }
        }

        return lastTitle
    }

    private static func extractCustomTitle(from line: String) -> String? {
        guard line.contains("\"custom-title\"") else { return nil }
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "custom-title",
              let title = obj["customTitle"] as? String,
              !title.isEmpty else { return nil }
        return title
    }

    /// Repair truncated session JSON files.
    /// Claude Code pre-allocates a fixed buffer and may not write the closing brace,
    /// leaving files like: {"pid":123,"sessionId":"abc","cwd":"/x","startedAt":1234,"kind":"interactive","entrypoint":"cli",
    /// We strip trailing whitespace/commas and close the object.
    private static func repairTruncatedJSON(_ data: Data) -> Data? {
        guard var json = String(data: data, encoding: .utf8) else { return nil }

        // Already valid? Don't touch it.
        json = json.trimmingCharacters(in: .whitespaces)
        if json.hasSuffix("}") { return nil }

        // Strip trailing whitespace, commas, and incomplete key-value pairs
        // e.g. `,"name":"Doc` or `,"name":` or just `,   `
        while json.last?.isWhitespace == true || json.last == "," {
            json.removeLast()
        }

        // If we're mid-value (e.g. `"name":"Doc` or `"name":123`),
        // drop back to the last comma to remove the incomplete field
        if !json.hasSuffix("}") && !json.hasSuffix("{") {
            // Check if we're inside an incomplete string value
            if let lastComma = json.lastIndex(of: ",") {
                let afterComma = json[json.index(after: lastComma)...]
                // If the remainder doesn't look like a complete key:value, drop it
                let trimmed = afterComma.trimmingCharacters(in: .whitespaces)
                if !trimmed.contains("}") {
                    // Count quotes to see if we have a complete value
                    let quoteCount = trimmed.filter { $0 == "\"" }.count
                    let hasColon = trimmed.contains(":")
                    // Complete field: "key":"value" (4 quotes + colon) or "key":number (2 quotes + colon + no trailing quote)
                    let looksComplete = hasColon && (quoteCount == 4 || (quoteCount == 2 && !trimmed.hasSuffix("\"")))
                    if !looksComplete {
                        json = String(json[...lastComma])
                        // Remove the trailing comma
                        while json.last == "," { json.removeLast() }
                    }
                }
            }
        }

        json += "}"

        return json.data(using: .utf8)
    }
}
