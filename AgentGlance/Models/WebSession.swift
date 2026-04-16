import Foundation

/// Codable snapshot of a Session for JSON serialization to web clients.
struct WebSession: Encodable {
    let id: String
    let name: String?
    let cwd: String
    let projectPath: String
    let projectName: String
    let state: String
    let workingDetail: String?
    let currentTool: String?
    let toolSummary: String?
    let toolCount: Int
    let elapsedSeconds: Int
    let elapsedFormatted: String
    let permissionMode: String?
    let lastUserPrompt: String?
    let todoCompleted: Int?
    let todoTotal: Int?
    let completionMessage: String?
    let modelName: String?
    let inputTokens: Int
    let outputTokens: Int

    /// Embedded pending decision — so HTTP poll and sync have full context
    let pending: WebPendingDecision?

    @MainActor
    static func from(_ session: Session, pending: PendingDecision?, hookServer: HookServer? = nil) -> WebSession {
        var webPending: WebPendingDecision?
        if let pending {
            webPending = WebPendingDecision.from(pending, session: session, hookServer: hookServer)
        }

        return WebSession(
            id: session.id,
            name: session.name,
            cwd: session.cwd,
            projectPath: session.projectPath,
            projectName: session.projectName,
            state: session.state.rawValue,
            workingDetail: session.workingDetail?.rawValue,
            currentTool: session.currentTool,
            toolSummary: pending?.toolSummary ?? session.pendingToolSummary,
            toolCount: session.toolCount,
            elapsedSeconds: Int(session.elapsed),
            elapsedFormatted: session.elapsedFormatted,
            permissionMode: session.permissionMode,
            lastUserPrompt: session.lastUserPrompt,
            todoCompleted: session.todoProgress?.completed,
            todoTotal: session.todoProgress?.total,
            completionMessage: session.lastAssistantMessage,
            modelName: session.modelName,
            inputTokens: session.inputTokens,
            outputTokens: session.outputTokens,
            pending: webPending
        )
    }
}
