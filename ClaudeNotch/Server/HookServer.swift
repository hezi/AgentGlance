import Foundation
import Network
import os

private let logger = Logger(subsystem: "com.claudenotch", category: "HookServer")

/// A parsed question from AskUserQuestion tool_input
struct ParsedQuestion: Identifiable {
    let id = UUID()
    let questionText: String
    let header: String
    let options: [String]
    let multiSelect: Bool
}

/// Represents a pending permission decision — the connection is held open until resolved
struct PendingDecision: Identifiable {
    let id: UUID
    let sessionId: String
    let toolName: String
    let toolInput: JSONValue?
    let toolSummary: String?
    let connection: NWConnection
    let receivedAt: Date

    var age: TimeInterval { Date().timeIntervalSince(receivedAt) }

    /// Parsed questions for AskUserQuestion tool calls
    var questions: [ParsedQuestion] {
        guard toolName == "AskUserQuestion",
              let toolInput,
              case .object(let obj) = toolInput,
              case .array(let questionsArr) = obj["questions"] else { return [] }

        return questionsArr.compactMap { q -> ParsedQuestion? in
            guard case .object(let qObj) = q,
                  case .string(let text) = qObj["question"],
                  case .string(let header) = qObj["header"] else { return nil }

            var optionLabels: [String] = []
            if case .array(let opts) = qObj["options"] {
                for opt in opts {
                    if case .object(let optObj) = opt,
                       case .string(let label) = optObj["label"] {
                        optionLabels.append(label)
                    }
                }
            }

            let multi: Bool
            if case .bool(let m) = qObj["multiSelect"] { multi = m }
            else { multi = false }

            return ParsedQuestion(questionText: text, header: header, options: optionLabels, multiSelect: multi)
        }
    }
}

@Observable
@MainActor
final class HookServer {
    private var listener: NWListener?
    private(set) var isRunning = false
    private(set) var port: UInt16

    var onEvent: ((HookPayload) -> Void)?
    /// Called when a permission decision is made (allow/deny/dismiss) with (sessionId, wasAllowed)
    var onDecision: ((String, Bool) -> Void)?

    /// Queued permission decisions per session, waiting for user input.
    /// Each session can have multiple pending approvals; the UI shows the first.
    private(set) var pendingDecisions: [String: [PendingDecision]] = [:]

    /// Convenience: get the next pending decision for a session
    func nextPending(for sessionId: String) -> PendingDecision? {
        pendingDecisions[sessionId]?.first
    }

    init(port: UInt16 = Constants.defaultPort) {
        self.port = port
    }

    func start() {
        stop()

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            logger.error("Failed to create listener: \(error.localizedDescription)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    logger.info("Hook server listening on port \(self?.port ?? 0)")
                    self?.isRunning = true
                case .failed(let error):
                    logger.error("Listener failed: \(error.localizedDescription)")
                    self?.isRunning = false
                case .cancelled:
                    self?.isRunning = false
                default:
                    break
                }
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        // Release all pending connections
        for (_, queue) in pendingDecisions {
            for pending in queue {
                sendEmptyResponse(pending.connection)
            }
        }
        pendingDecisions.removeAll()

        listener?.cancel()
        listener = nil
        isRunning = false
    }

    func restart(on newPort: UInt16) {
        port = newPort
        start()
    }

    // MARK: - Permission Decision API

    /// Pop the next pending decision from the queue for a session
    private func dequeue(sessionId: String) -> PendingDecision? {
        guard var queue = pendingDecisions[sessionId], !queue.isEmpty else { return nil }
        let pending = queue.removeFirst()
        if queue.isEmpty {
            pendingDecisions.removeValue(forKey: sessionId)
        } else {
            pendingDecisions[sessionId] = queue
        }
        return pending
    }

    /// Number of queued approvals for a session
    func pendingCount(for sessionId: String) -> Int {
        pendingDecisions[sessionId]?.count ?? 0
    }

    /// Allow a pending permission request
    func allowPermission(sessionId: String) {
        guard let pending = dequeue(sessionId: sessionId) else { return }

        let decision = """
        {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
        """
        let response = HTTPParser.okResponse(body: decision)
        pending.connection.send(content: response, completion: .contentProcessed { _ in
            pending.connection.cancel()
        })
        logger.info("Allowed permission for session \(sessionId) (\(self.pendingCount(for: sessionId)) remaining)")
        onDecision?(sessionId, true)
    }

    /// Allow and add a permanent rule so this tool/command is never asked again
    func allowAlwaysPermission(sessionId: String) {
        guard let pending = dequeue(sessionId: sessionId) else { return }

        struct Rule: Encodable {
            let toolName: String
            let ruleContent: String?
        }
        struct PermUpdate: Encodable {
            let type = "addRules"
            let rules: [Rule]
            let behavior = "allow"
            let destination = "projectSettings"
        }
        struct Decision: Encodable {
            let behavior = "allow"
            let updatedPermissions: [PermUpdate]
        }
        struct HookOutput: Encodable {
            let hookEventName = "PermissionRequest"
            let decision: Decision
        }
        struct Response: Encodable {
            let hookSpecificOutput: HookOutput
        }

        var ruleContent: String?
        if let toolInput = pending.toolInput, case .object(let obj) = toolInput {
            if case .string(let cmd) = obj["command"] {
                ruleContent = cmd
            } else if case .string(let path) = obj["file_path"] {
                ruleContent = path
            }
        }

        let rule = Rule(toolName: pending.toolName, ruleContent: ruleContent)
        let resp = Response(
            hookSpecificOutput: HookOutput(
                decision: Decision(
                    updatedPermissions: [PermUpdate(rules: [rule])]
                )
            )
        )

        let body: String
        if let data = try? JSONEncoder().encode(resp), let json = String(data: data, encoding: .utf8) {
            body = json
        } else {
            body = "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"allow\"}}}"
        }

        logger.info("Always-allow response: \(body)")

        let response = HTTPParser.okResponse(body: body)
        pending.connection.send(content: response, completion: .contentProcessed { _ in
            pending.connection.cancel()
        })
        logger.info("Always-allowed \(pending.toolName) for session \(sessionId) (\(self.pendingCount(for: sessionId)) remaining)")
        onDecision?(sessionId, true)
    }

    /// Answer an AskUserQuestion with selected options
    func answerQuestion(sessionId: String, answers: [String: String]) {
        guard let pending = dequeue(sessionId: sessionId) else { return }

        // Build the response using Codable
        struct QuestionOption: Encodable {
            let label: String
            let description: String?
        }
        struct Question: Encodable {
            let question: String
            let header: String
            let options: [QuestionOption]
            let multiSelect: Bool
        }
        struct UpdatedInput: Encodable {
            let questions: [Question]
            let answers: [String: String]
        }
        struct Decision: Encodable {
            let behavior = "allow"
            let updatedInput: UpdatedInput
        }
        struct HookOutput: Encodable {
            let hookEventName = "PermissionRequest"
            let decision: Decision
        }
        struct Response: Encodable {
            let hookSpecificOutput: HookOutput
        }

        // Rebuild questions from the parsed data
        let parsedQuestions = pending.questions
        let questions = parsedQuestions.map { q in
            Question(
                question: q.questionText,
                header: q.header,
                options: q.options.map { QuestionOption(label: $0, description: nil) },
                multiSelect: q.multiSelect
            )
        }

        let resp = Response(
            hookSpecificOutput: HookOutput(
                decision: Decision(
                    updatedInput: UpdatedInput(questions: questions, answers: answers)
                )
            )
        )

        let body: String
        if let data = try? JSONEncoder().encode(resp), let json = String(data: data, encoding: .utf8) {
            body = json
        } else {
            // Fallback — just allow without answers, falls through to CLI
            body = "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"allow\"}}}"
        }

        logger.info("Answered question for session \(sessionId): \(answers)")

        let response = HTTPParser.okResponse(body: body)
        pending.connection.send(content: response, completion: .contentProcessed { _ in
            pending.connection.cancel()
        })
        onDecision?(sessionId, true)
    }

    /// Deny a pending permission request
    func denyPermission(sessionId: String, message: String = "Denied from Claude Notch") {
        guard let pending = dequeue(sessionId: sessionId) else { return }

        let escapedMessage = message.replacingOccurrences(of: "\"", with: "\\\"")
        let decision = """
        {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"\(escapedMessage)"}}}
        """
        let response = HTTPParser.okResponse(body: decision)
        pending.connection.send(content: response, completion: .contentProcessed { _ in
            pending.connection.cancel()
        })
        logger.info("Denied permission for session \(sessionId) (\(self.pendingCount(for: sessionId)) remaining)")
        onDecision?(sessionId, false)
    }

    /// Dismiss — let the normal Claude Code permission dialog handle it
    func dismissPermission(sessionId: String) {
        guard let pending = dequeue(sessionId: sessionId) else { return }
        sendEmptyResponse(pending.connection)
        logger.info("Dismissed permission for session \(sessionId) (\(self.pendingCount(for: sessionId)) remaining)")
        onDecision?(sessionId, false)
    }

    /// Allow a specific pending decision by UUID (for show-all mode)
    func allowSpecificPermission(id: UUID, sessionId: String) {
        guard var queue = pendingDecisions[sessionId],
              let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let pending = queue.remove(at: index)
        if queue.isEmpty { pendingDecisions.removeValue(forKey: sessionId) }
        else { pendingDecisions[sessionId] = queue }

        let decision = """
        {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
        """
        let response = HTTPParser.okResponse(body: decision)
        pending.connection.send(content: response, completion: .contentProcessed { _ in
            pending.connection.cancel()
        })
        logger.info("Allowed specific permission \(pending.toolName) for session \(sessionId)")
        if pendingCount(for: sessionId) == 0 {
            onDecision?(sessionId, true)
        }
    }

    /// Deny a specific pending decision by UUID (for show-all mode)
    func denySpecificPermission(id: UUID, sessionId: String) {
        guard var queue = pendingDecisions[sessionId],
              let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let pending = queue.remove(at: index)
        if queue.isEmpty { pendingDecisions.removeValue(forKey: sessionId) }
        else { pendingDecisions[sessionId] = queue }

        let decision = """
        {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Claude Notch"}}}
        """
        let response = HTTPParser.okResponse(body: decision)
        pending.connection.send(content: response, completion: .contentProcessed { _ in
            pending.connection.cancel()
        })
        logger.info("Denied specific permission \(pending.toolName) for session \(sessionId)")
        if pendingCount(for: sessionId) == 0 {
            onDecision?(sessionId, false)
        }
    }

    /// Flush all pending decisions for a session (they're stale — user handled it in the TUI)
    func flushPendingDecisions(for sessionId: String) {
        guard let queue = pendingDecisions.removeValue(forKey: sessionId) else { return }
        for pending in queue {
            sendEmptyResponse(pending.connection)
        }
        if !queue.isEmpty {
            logger.info("Flushed \(queue.count) stale pending decision(s) for session \(sessionId)")
        }
    }

    var hasPendingDecisions: Bool {
        pendingDecisions.values.contains { !$0.isEmpty }
    }

    // MARK: - Connection Handling

    private nonisolated func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))

        var buffer = Data()

        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data {
                    buffer.append(data)
                }

                if let request = HTTPParser.parse(buffer) {
                    self.processRequest(request, connection: connection)
                    return
                }

                if isComplete || error != nil {
                    self.sendEmptyResponse(connection)
                    return
                }

                receiveMore()
            }
        }

        receiveMore()
    }

    private nonisolated func processRequest(_ request: HTTPRequest, connection: NWConnection) {
        guard request.method == "POST",
              request.path.hasPrefix("/hook/"),
              !request.body.isEmpty else {
            sendEmptyResponse(connection)
            return
        }

        let payload: HookPayload
        do {
            payload = try JSONDecoder().decode(HookPayload.self, from: request.body)
        } catch {
            logger.error("Failed to decode hook payload: \(error.localizedDescription)")
            sendEmptyResponse(connection)
            return
        }

        // For PermissionRequest: hold the connection open for user decision
        if request.path == "/hook/PermissionRequest" {
            let summary = SessionManager.extractToolSummary(
                toolName: payload.tool_name,
                toolInput: payload.tool_input
            )

            let pending = PendingDecision(
                id: UUID(),
                sessionId: payload.session_id,
                toolName: payload.tool_name ?? "Unknown",
                toolInput: payload.tool_input,
                toolSummary: summary,
                connection: connection,
                receivedAt: Date()
            )

            Task { @MainActor [weak self] in
                guard let self else { return }
                // Append to the queue for this session
                var queue = pendingDecisions[payload.session_id] ?? []
                queue.append(pending)
                pendingDecisions[payload.session_id] = queue
                logger.info("Queued permission \(pending.toolName) for session \(payload.session_id) (queue size: \(queue.count))")
                onEvent?(payload)
            }
            return
        }

        // For all other events: respond immediately
        sendEmptyResponse(connection)

        Task { @MainActor [weak self] in
            self?.onEvent?(payload)
        }
    }

    private nonisolated func sendEmptyResponse(_ connection: NWConnection) {
        let response = HTTPParser.okResponse()
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Mock Pending Decisions (for previews and Test Events)

    /// Queue a mock pending decision without a real HTTP connection.
    /// Allow/Deny will silently no-op on the dummy connection.
    func addMockPending(sessionId: String, toolName: String, toolInput: JSONValue? = nil, toolSummary: String? = nil) {
        let dummy = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        let pending = PendingDecision(
            id: UUID(),
            sessionId: sessionId,
            toolName: toolName,
            toolInput: toolInput,
            toolSummary: toolSummary,
            connection: dummy,
            receivedAt: Date()
        )
        var queue = pendingDecisions[sessionId] ?? []
        queue.append(pending)
        pendingDecisions[sessionId] = queue
    }
}
