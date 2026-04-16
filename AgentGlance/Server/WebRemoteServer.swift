import Foundation
import Network
import os

private let logger = Logger(subsystem: "app.agentglance", category: "WebRemoteServer")

/// A connected WebSocket client
private final class WebRemoteClient: @unchecked Sendable {
    let connection: NWConnection
    let token: String
    var lastSeen: Date

    init(connection: NWConnection, token: String) {
        self.connection = connection
        self.token = token
        self.lastSeen = Date()
    }
}

/// Lightweight HTTP + WebSocket server for the mobile web remote UI.
/// Uses two listeners:
///   - TCP on port 7484 for HTTP (static files, /pair, /api/status)
///   - NWProtocolWebSocket on port 7485 for WebSocket connections
@MainActor
final class WebRemoteServer {
    private var httpListener: NWListener?
    private var wsListener: NWListener?
    private(set) var isRunning = false

    private var clients: [ObjectIdentifier: WebRemoteClient] = [:]

    private let hookServer: HookServer
    private let sessionManager: SessionManager
    private let pairingManager: PairingManager
    private let httpPort: UInt16
    private let wsPort: UInt16

    init(hookServer: HookServer, sessionManager: SessionManager, pairingManager: PairingManager, port: UInt16 = Constants.webRemotePort) {
        self.hookServer = hookServer
        self.sessionManager = sessionManager
        self.pairingManager = pairingManager
        self.httpPort = port
        self.wsPort = port + 1 // 7485
    }

    func start() {
        stop()

        pairingManager.onRevokeAll = { [weak self] in
            self?.disconnectAllClients()
        }

        // --- HTTP listener (plain TCP) ---
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            httpListener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: httpPort)!)
        } catch {
            logger.error("Failed to create HTTP listener: \(error.localizedDescription)")
            return
        }

        httpListener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    logger.info("Web remote HTTP server listening on port \(self?.httpPort ?? 0)")
                case .failed(let error):
                    logger.error("HTTP listener failed: \(error.localizedDescription)")
                    self?.isRunning = false
                default: break
                }
            }
        }
        httpListener?.newConnectionHandler = { [weak self] conn in
            self?.handleHTTPConnection(conn)
        }
        httpListener?.start(queue: .global(qos: .userInitiated))

        // --- WebSocket listener (NWProtocolWebSocket) ---
        do {
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true

            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

            wsListener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: wsPort)!)
        } catch {
            logger.error("Failed to create WebSocket listener: \(error.localizedDescription)")
            return
        }

        wsListener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    logger.info("Web remote WebSocket server listening on port \(self?.wsPort ?? 0)")
                    self?.isRunning = true
                case .failed(let error):
                    logger.error("WebSocket listener failed: \(error.localizedDescription)")
                    self?.isRunning = false
                default: break
                }
            }
        }
        wsListener?.newConnectionHandler = { [weak self] conn in
            self?.handleWSConnection(conn)
        }
        wsListener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        pairingManager.onRevokeAll = nil
        disconnectAllClients()
        httpListener?.cancel()
        httpListener = nil
        wsListener?.cancel()
        wsListener = nil
        isRunning = false
    }

    func disconnectAllClients() {
        for client in clients.values {
            // Send WebSocket close via NWProtocolWebSocket metadata
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            metadata.closeCode = .protocolCode(.normalClosure)
            let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
            client.connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
                client.connection.cancel()
            })
        }
        let count = clients.count
        clients.removeAll()
        if count > 0 {
            logger.info("Disconnected \(count) web remote client(s)")
        }
    }

    // MARK: - Broadcasting

    func broadcastSessionUpdate(_ session: Session) {
        let pending = hookServer.nextPending(for: session.id)
        let webSession = WebSession.from(session, pending: pending, hookServer: hookServer)
        broadcast(ServerMessage.sessionUpdate(webSession))
    }

    func broadcastSessionRemove(_ sessionId: String) {
        broadcast(ServerMessage.sessionRemove(sessionId))
    }

    func broadcastDecisionResolved(_ sessionId: String) {
        broadcast(ServerMessage.decisionResolved(sessionId))
    }

    // MARK: - HTTP Connection Handling

    private nonisolated func handleHTTPConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))

        var buffer = Data()

        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data { buffer.append(data) }

                if let request = HTTPParser.parse(buffer) {
                    self.routeHTTPRequest(request, connection: connection)
                    return
                }

                if isComplete || error != nil {
                    connection.cancel()
                    return
                }

                receiveMore()
            }
        }

        receiveMore()
    }

    private nonisolated func routeHTTPRequest(_ request: HTTPRequest, connection: NWConnection) {
        if request.method == "POST" && request.path == "/pair" {
            handlePairRequest(request, connection: connection)
            return
        }

        // POST /api/action — handle actions when WS isn't available
        if request.method == "POST" && request.path == "/api/action" {
            Task { @MainActor in
                let token = request.headers["authorization"]?.replacingOccurrences(of: "Bearer ", with: "")
                guard let token, self.pairingManager.isValidToken(token) else {
                    let resp = HTTPParser.buildHTTPResponse(status: 401, statusText: "Unauthorized", contentType: "text/plain", body: Data("Unauthorized".utf8))
                    connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }

                if let message = try? JSONDecoder().decode(ClientMessage.self, from: request.body) {
                    // Create a dummy client for the handleClientText path
                    self.processClientAction(message)
                }

                let resp = HTTPParser.okResponse()
                connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
            }
            return
        }

        if request.method == "GET" && request.path.hasPrefix("/api/status") {
            Task { @MainActor in
                let token = request.headers["authorization"]?.replacingOccurrences(of: "Bearer ", with: "")
                guard let token, self.pairingManager.isValidToken(token) else {
                    let resp = HTTPParser.buildHTTPResponse(status: 401, statusText: "Unauthorized", contentType: "text/plain", body: Data("Unauthorized".utf8))
                    connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }

                let payload = self.buildSyncPayload()
                if let body = try? JSONEncoder().encode(payload) {
                    let resp = HTTPParser.buildHTTPResponse(status: 200, statusText: "OK", contentType: "application/json", body: body)
                    connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
                } else {
                    let resp = HTTPParser.buildHTTPResponse(status: 500, statusText: "Error", contentType: "text/plain", body: Data("Encode error".utf8))
                    connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            return
        }

        if request.method == "GET" {
            handleStaticFile(request, connection: connection)
            return
        }

        let resp = HTTPParser.buildHTTPResponse(status: 404, statusText: "Not Found", contentType: "text/plain", body: Data("Not Found".utf8))
        connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
    }

    private nonisolated func handlePairRequest(_ request: HTTPRequest, connection: NWConnection) {
        struct PairRequest: Decodable { let code: String; let deviceName: String? }
        struct PairResponse: Encodable { let token: String?; let error: String? }

        guard let req = try? JSONDecoder().decode(PairRequest.self, from: request.body) else {
            let body = try! JSONEncoder().encode(PairResponse(token: nil, error: "Invalid request"))
            let resp = HTTPParser.buildHTTPResponse(status: 400, statusText: "Bad Request", contentType: "application/json", body: body)
            connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
            return
        }

        Task { @MainActor in
            let remoteIP = connection.endpoint.debugDescription
            let token = self.pairingManager.validateCode(req.code, ip: remoteIP, deviceName: req.deviceName ?? "Phone")

            let response: PairResponse
            let status: Int
            if let token {
                response = PairResponse(token: token, error: nil)
                status = 200
            } else {
                response = PairResponse(token: nil, error: "Invalid or expired code")
                status = 403
            }

            let body = try! JSONEncoder().encode(response)
            let resp = HTTPParser.buildHTTPResponse(status: status, statusText: status == 200 ? "OK" : "Forbidden", contentType: "application/json", body: body)
            connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    // MARK: - WebSocket Connection Handling (NWProtocolWebSocket)

    private nonisolated func handleWSConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        logger.info("WebSocket connection starting...")

        // Wait for the first WebSocket message which must contain the auth token
        receiveWSMessage(connection) { [weak self] data in
            guard let self else { return }

            guard let data else {
                logger.info("WebSocket auth: no data received, closing")
                connection.cancel()
                return
            }

            logger.info("WebSocket auth: received \(data.count) bytes")

            guard let authMsg = try? JSONDecoder().decode(ClientMessage.self, from: data),
                  authMsg.type == .auth,
                  let token = authMsg.token else {
                logger.info("WebSocket auth: invalid message, closing")
                connection.cancel()
                return
            }

            logger.info("WebSocket auth: token received, validating...")

            Task { @MainActor [weak self] in
                guard let self, self.pairingManager.isValidToken(token) else {
                    logger.info("WebSocket token invalid, closing")
                    connection.cancel()
                    return
                }

                let client = WebRemoteClient(connection: connection, token: token)
                self.clients[ObjectIdentifier(connection)] = client
                logger.info("WebSocket client authenticated (total: \(self.clients.count))")

                // Send initial sync
                let payload = self.buildSyncPayload()
                logger.info("WebSocket sending sync with \(payload.sessions.count) sessions")
                self.sendWSMessage(ServerMessage.sync(payload), to: client)

                // Start reading messages
                self.readWSMessages(from: client)
            }
        }
    }

    /// Receive a single WebSocket message using NWProtocolWebSocket framing
    private nonisolated func receiveWSMessage(_ connection: NWConnection, handler: @escaping (Data?) -> Void) {
        connection.receiveMessage { content, context, isComplete, error in
            if let error {
                logger.info("WebSocket receive error: \(error.localizedDescription)")
                handler(nil)
                return
            }

            // Check this is a WebSocket text/binary message
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch metadata.opcode {
                case .text, .binary:
                    handler(content)
                case .close:
                    handler(nil)
                default:
                    // Pings are auto-handled by NWProtocolWebSocket
                    handler(content)
                }
            } else {
                handler(content)
            }
        }
    }

    /// Continuously read WebSocket messages from a client
    private nonisolated func readWSMessages(from client: WebRemoteClient) {
        client.connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self else { return }

            if let error {
                logger.info("WebSocket peer disconnected: \(error.localizedDescription)")
                Task { @MainActor [weak self] in self?.removeClient(client) }
                return
            }

            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                if metadata.opcode == .close {
                    logger.info("WebSocket client sent close frame")
                    Task { @MainActor [weak self] in self?.removeClient(client) }
                    return
                }
            }

            if let content, !content.isEmpty {
                Task { @MainActor [weak self] in
                    self?.handleClientText(content, from: client)
                }
            }

            if isComplete && (content == nil || content?.isEmpty == true) {
                logger.info("WebSocket connection closed by peer")
                Task { @MainActor [weak self] in self?.removeClient(client) }
                return
            }

            // Continue reading
            self.readWSMessages(from: client)
        }
    }

    // MARK: - Client Message Handling

    private func handleClientText(_ data: Data, from client: WebRemoteClient) {
        client.lastSeen = Date()

        guard let message = try? JSONDecoder().decode(ClientMessage.self, from: data) else {
            logger.warning("Failed to decode client message")
            return
        }

        if message.type == .ping {
            sendWSMessage(ServerMessage.pong, to: client)
            return
        }
        if message.type == .auth { return }

        processClientAction(message)
    }

    /// Dispatch a client action to the hook server. Used by both WS and HTTP paths.
    private func processClientAction(_ message: ClientMessage) {
        switch message.type {
        case .auth, .ping:
            break
        case .allow:
            guard let sessionId = message.sessionId else { return }
            hookServer.allowPermission(sessionId: sessionId)
        case .allowAlways:
            guard let sessionId = message.sessionId else { return }
            hookServer.allowAlwaysPermission(sessionId: sessionId)
        case .deny:
            guard let sessionId = message.sessionId else { return }
            hookServer.denyPermission(sessionId: sessionId)
        case .dismiss:
            guard let sessionId = message.sessionId else { return }
            hookServer.dismissPermission(sessionId: sessionId)
        case .answerQuestion:
            guard let sessionId = message.sessionId, let answers = message.answers else { return }
            hookServer.answerQuestion(sessionId: sessionId, answers: answers)
        case .approvePlan:
            guard let sessionId = message.sessionId else { return }
            hookServer.allowPermission(sessionId: sessionId)
        case .rejectPlan:
            guard let sessionId = message.sessionId else { return }
            hookServer.denyPermission(sessionId: sessionId, message: message.message ?? "Plan rejected from web remote")
        }
    }

    // MARK: - Sending (NWProtocolWebSocket)

    private func sendWSMessage(_ message: ServerMessage, to client: WebRemoteClient) {
        guard let data = try? JSONEncoder().encode(message) else {
            logger.error("Failed to encode WebSocket message")
            return
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])

        client.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            if let error {
                logger.error("WebSocket send failed: \(error.localizedDescription)")
            } else {
                logger.info("WebSocket sent \(data.count) bytes")
            }
        })
    }

    private func broadcast(_ message: ServerMessage) {
        guard !clients.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(message) else {
            logger.error("Broadcast: failed to encode message")
            return
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let clientCount = clients.count

        for client in clients.values {
            let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
            client.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error {
                    logger.error("Broadcast send failed: \(error.localizedDescription)")
                }
            })
        }
        logger.info("Broadcast \(data.count) bytes to \(clientCount) client(s)")
    }

    private func removeClient(_ client: WebRemoteClient) {
        clients.removeValue(forKey: ObjectIdentifier(client.connection))
        client.connection.cancel()
        logger.info("WebSocket client disconnected (total: \(self.clients.count))")
    }

    // MARK: - Sync Payload

    private func buildSyncPayload() -> ServerMessage.SyncPayload {
        let sessions = sessionManager.activeSessions.map { session in
            WebSession.from(session, pending: hookServer.nextPending(for: session.id), hookServer: hookServer)
        }

        let groupModeRaw = UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.sessionGroupMode) ?? SessionGroupMode.none.rawValue
        let sortModeRaw = UserDefaults.standard.string(forKey: Constants.UserDefaultsKeys.groupSortMode) ?? GroupSortMode.lastUpdated.rawValue
        let groupMode = SessionGroupMode(rawValue: groupModeRaw) ?? .none
        let sortMode = GroupSortMode(rawValue: sortModeRaw) ?? .lastUpdated

        var webGroups: [ServerMessage.WebSessionGroup]?
        if groupMode != .none {
            let groups = SessionGrouper.group(
                sessions: sessionManager.activeSessions,
                by: groupMode,
                sortedBy: sortMode
            )
            webGroups = groups.map { group in
                ServerMessage.WebSessionGroup(
                    id: group.id,
                    title: group.title,
                    sessionIds: group.sessions.map(\.id)
                )
            }
        }

        let rowTitle = DisplayTemplate.load(forKey: Constants.UserDefaultsKeys.rowTitleTemplate, default: .defaultRowTitle)
        let rowDetail = DisplayTemplate.load(forKey: Constants.UserDefaultsKeys.rowDetailTemplate, default: .defaultRowDetail)

        return ServerMessage.SyncPayload(
            sessions: sessions,
            groupMode: groupModeRaw,
            sortMode: sortModeRaw,
            groups: webGroups,
            rowTitleFormat: rowTitle.format,
            rowDetailFormat: rowDetail.format
        )
    }

    // MARK: - Static File Serving

    private nonisolated func handleStaticFile(_ request: HTTPRequest, connection: NWConnection) {
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path

        let resourceName: String
        let contentType: String
        let ext: String

        switch path {
        case "/", "/index.html":
            resourceName = "index"; contentType = "text/html"; ext = "html"
        case "/style.css":
            resourceName = "style"; contentType = "text/css"; ext = "css"
        case "/app.js":
            resourceName = "app"; contentType = "application/javascript"; ext = "js"
        case "/silent.mp4":
            resourceName = "silent"; contentType = "video/mp4"; ext = "mp4"
        default:
            resourceName = "index"; contentType = "text/html"; ext = "html"
        }

        guard let url = Bundle.main.url(forResource: resourceName, withExtension: ext, subdirectory: "WebRemote"),
              let data = try? Data(contentsOf: url) else {
            let resp = HTTPParser.buildHTTPResponse(status: 404, statusText: "Not Found", contentType: "text/plain", body: Data("Not Found".utf8))
            connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
            return
        }

        let headers = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType); charset=utf-8\r\nContent-Length: \(data.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        var resp = Data(headers.utf8)
        resp.append(data)
        connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Network Interface Discovery

    nonisolated static func reachableAddresses(port: UInt16) -> [(label: String, url: String)] {
        var results: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return results }
        defer { freeifaddrs(first) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = ptr {
            defer { ptr = ifa.pointee.ifa_next }

            guard let addr = ifa.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: ifa.pointee.ifa_name)
            guard name != "lo0" else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: hostname)

                let label: String
                if ip.hasPrefix("100.") {
                    label = "Tailscale"
                } else if name.hasPrefix("utun") {
                    label = "VPN (\(name))"
                } else {
                    label = "LAN (\(name))"
                }

                results.append((label, "http://\(ip):\(port)"))
            }
        }

        return results
    }
}
