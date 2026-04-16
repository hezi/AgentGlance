import Foundation

/// WebSocket protocol messages between the web remote client and server.

// MARK: - Server → Client

enum ServerMessage: Encodable {
    case sync(SyncPayload)
    case sessionUpdate(WebSession)
    case sessionRemove(String)
    case pendingDecision(WebPendingDecision)
    case decisionResolved(String)
    case pong

    struct SyncPayload: Encodable {
        let sessions: [WebSession]
        let groupMode: String   // "none", "project", "status"
        let sortMode: String    // "alphabetical", "lastUpdated"
        let groups: [WebSessionGroup]?
        let rowTitleFormat: String?
        let rowDetailFormat: String?
    }

    struct WebSessionGroup: Encodable {
        let id: String
        let title: String
        let sessionIds: [String]
    }

    private enum CodingKeys: String, CodingKey {
        case type, payload
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sync(let payload):
            try container.encode("sync", forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .sessionUpdate(let session):
            try container.encode("sessionUpdate", forKey: .type)
            try container.encode(session, forKey: .payload)
        case .sessionRemove(let sessionId):
            try container.encode("sessionRemove", forKey: .type)
            try container.encode(["sessionId": sessionId], forKey: .payload)
        case .pendingDecision(let decision):
            try container.encode("pendingDecision", forKey: .type)
            try container.encode(decision, forKey: .payload)
        case .decisionResolved(let sessionId):
            try container.encode("decisionResolved", forKey: .type)
            try container.encode(["sessionId": sessionId], forKey: .payload)
        case .pong:
            try container.encode("pong", forKey: .type)
        }
    }
}

/// A pending decision serialized for the web client
struct WebPendingDecision: Encodable {
    let sessionId: String
    let toolName: String
    let toolSummary: String?
    let type: String // "permission", "question", "plan"
    let pendingCount: Int
    let questions: [WebQuestion]?
    let planPreview: String?
    let planFull: String?

    // Edit tool context
    let filePath: String?
    let oldString: String?
    let newString: String?

    // Write tool context
    let isNewFile: Bool?

    // WebFetch/WebSearch context
    let url: String?

    struct WebQuestion: Encodable {
        let questionText: String
        let header: String
        let options: [String]
        let multiSelect: Bool
    }

    @MainActor
    static func from(_ pending: PendingDecision, session: Session, hookServer: HookServer?) -> WebPendingDecision {
        let decisionType: String
        var questions: [WebQuestion]?
        var planPreview: String?
        var planFull: String?

        if pending.toolName == "AskUserQuestion" {
            decisionType = "question"
            questions = pending.questions.map { q in
                WebQuestion(questionText: q.questionText, header: q.header, options: q.options, multiSelect: q.multiSelect)
            }
        } else if pending.toolName == "ExitPlanMode" {
            decisionType = "plan"
            planPreview = session.pendingPlanPreview
            planFull = session.pendingPlanFull
        } else {
            decisionType = "permission"
        }

        var filePath: String?
        var oldString: String?
        var newString: String?
        var isNewFile: Bool?
        var url: String?

        if let input = pending.toolInput, case .object(let obj) = input {
            if case .string(let fp) = obj["file_path"] { filePath = fp }
            switch pending.toolName {
            case "Edit":
                if case .string(let os) = obj["old_string"] { oldString = os }
                if case .string(let ns) = obj["new_string"] { newString = ns }
            case "Write":
                if let fp = filePath {
                    isNewFile = !FileManager.default.fileExists(atPath: fp)
                }
            case "WebFetch":
                if case .string(let u) = obj["url"] { url = u }
            case "WebSearch":
                if case .string(let q) = obj["query"] { url = q }
            default: break
            }
        }

        return WebPendingDecision(
            sessionId: session.id,
            toolName: pending.toolName,
            toolSummary: pending.toolSummary,
            type: decisionType,
            pendingCount: hookServer?.pendingCount(for: session.id) ?? 1,
            questions: questions,
            planPreview: planPreview,
            planFull: planFull,
            filePath: filePath,
            oldString: oldString,
            newString: newString,
            isNewFile: isNewFile,
            url: url
        )
    }
}

// MARK: - Client → Server

struct ClientMessage: Decodable {
    let type: ClientMessageType
    let sessionId: String?
    let token: String?
    let answers: [String: String]?
    let message: String?

    enum ClientMessageType: String, Decodable {
        case auth
        case allow
        case allowAlways
        case deny
        case dismiss
        case answerQuestion
        case approvePlan
        case rejectPlan
        case ping
    }
}
