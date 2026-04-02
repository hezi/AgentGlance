#!/usr/bin/env swift
// agentglance-bridge — Hook bridge for AgentGlance
// Reads hook JSON from stdin, enriches with terminal environment,
// forwards to Unix socket (or falls back to HTTP).

import Foundation

// MARK: - Read stdin

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
guard !stdinData.isEmpty else { exit(0) }

// MARK: - Parse and enrich JSON

guard var json = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any] else {
    // Not valid JSON — pass through unchanged
    FileHandle.standardOutput.write(stdinData)
    exit(0)
}

let eventName = json["hook_event_name"] as? String ?? "Unknown"
let isPermission = eventName == "PermissionRequest"

// Enrich with terminal environment variables
let env = ProcessInfo.processInfo.environment
let enrichKeys: [(jsonKey: String, envKey: String)] = [
    ("_ag_term_program", "TERM_PROGRAM"),
    ("_ag_iterm_session_id", "ITERM_SESSION_ID"),
    ("_ag_tmux", "TMUX"),
    ("_ag_tmux_pane", "TMUX_PANE"),
    ("_ag_kitty_window_id", "KITTY_WINDOW_ID"),
]

for (jsonKey, envKey) in enrichKeys {
    if let val = env[envKey], !val.isEmpty {
        json[jsonKey] = val
    }
}

// Detect TTY
if let tty = ttyname(STDIN_FILENO) {
    json["_ag_tty"] = String(cString: tty)
}

// Read session name from Claude's session file (~/.claude/sessions/<pid>.json)
// The bridge runs as a child of the Claude Code process, so we walk up the process
// tree to find the Claude PID and read its session file.
if json["session_name"] == nil {
    let sessionsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/sessions")
    // Try our own PID's ancestors — Claude Code is typically 1-3 levels up
    var checkPid = ProcessInfo.processInfo.processIdentifier
    for _ in 0..<6 {
        let path = (sessionsDir as NSString).appendingPathComponent("\(checkPid).json")
        if let data = FileManager.default.contents(atPath: path),
           let sess = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = sess["name"] as? String, !name.isEmpty {
            json["session_name"] = name
            break
        }
        // Walk to parent PID
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, checkPid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
        let ppid = info.kp_eproc.e_ppid
        guard ppid > 1 else { break }
        checkPid = ppid
    }
}

guard let enrichedData = try? JSONSerialization.data(withJSONObject: json) else {
    exit(1)
}

// MARK: - OSC 2 tab title for Ghostty

// Set terminal tab title to include project + session ID prefix for reliable matching
if let termProg = env["TERM_PROGRAM"]?.lowercased(),
   ["ghostty", "xterm-ghostty"].contains(termProg),
   env["TMUX"] == nil,
   eventName == "SessionStart" || eventName == "UserPromptSubmit" {
    let sessionId = json["session_id"] as? String ?? ""
    let cwd = json["cwd"] as? String ?? ""
    let project = (cwd as NSString).lastPathComponent
    let sessionName = json["session_name"] as? String
    let prefix = String(sessionId.prefix(12))
    let title = sessionName != nil ? "\(project) · \(sessionName!)" : "\(project) · \(prefix)"
    // Write to stderr so it doesn't interfere with stdout (permission responses)
    FileHandle.standardError.write(Data("\u{1b}]2;\(title)\u{07}".utf8))
}

// MARK: - Build HTTP request

let httpRequest: Data = {
    let path = "/hook/\(eventName)"
    let body = enrichedData
    var request = "POST \(path) HTTP/1.1\r\n"
    request += "Host: localhost\r\n"
    request += "Content-Type: application/json\r\n"
    request += "Content-Length: \(body.count)\r\n"
    request += "Connection: close\r\n"
    request += "\r\n"
    var data = request.data(using: .utf8)!
    data.append(body)
    return data
}()

// MARK: - Send via Unix socket

let socketPath = "/tmp/agentglance.sock"

func sendViaSocket() -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { if !isPermission { close(fd) } }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
            for (i, byte) in pathBytes.enumerated() { dest[i] = byte }
        }
    }

    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else { return false }

    // Send HTTP request
    _ = httpRequest.withUnsafeBytes { bytes in
        send(fd, bytes.baseAddress!, bytes.count, 0)
    }

    if isPermission {
        // Read response and write to stdout
        var response = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            response.append(contentsOf: buf[..<n])
        }
        close(fd)

        // Extract HTTP body (after \r\n\r\n)
        if let range = response.range(of: Data("\r\n\r\n".utf8)) {
            let body = response[range.upperBound...]
            FileHandle.standardOutput.write(body)
        }
    }

    return true
}

// MARK: - Fallback: send via HTTP

func sendViaHTTP() {
    let port = ProcessInfo.processInfo.environment["AG_PORT"] ?? "7483"
    guard let url = URL(string: "http://localhost:\(port)/hook/\(eventName)") else { exit(1) }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = enrichedData
    request.timeoutInterval = isPermission ? 120 : 3

    let sem = DispatchSemaphore(value: 0)
    let task = URLSession.shared.dataTask(with: request) { data, _, _ in
        if isPermission, let data {
            FileHandle.standardOutput.write(data)
        }
        sem.signal()
    }
    task.resume()
    sem.wait()
}

// MARK: - Main

if !sendViaSocket() {
    sendViaHTTP()
}
