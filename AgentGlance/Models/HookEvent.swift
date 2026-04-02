import Foundation

enum HookEventType: String, Codable, CaseIterable {
    case SessionStart
    case SessionEnd
    case PreToolUse
    case PostToolUse
    case Stop
    case Notification
    case PermissionRequest
    case UserPromptSubmit
}

struct HookPayload: Codable {
    let session_id: String
    let cwd: String
    let hook_event_name: String

    // Tool events
    let tool_name: String?
    let tool_input: JSONValue?

    // Notification events
    let notification_type: String?

    // Session end
    let reason: String?

    // Session metadata
    let permission_mode: String?

    // Stop event: agent's last response message
    let last_assistant_message: String?

    // Session name (from --resume or Claude-generated title)
    let session_name: String?

    // Bridge enrichment: terminal environment data
    let _ag_term_program: String?
    let _ag_iterm_session_id: String?
    let _ag_tmux: String?
    let _ag_tmux_pane: String?
    let _ag_kitty_window_id: String?
    let _ag_tty: String?

    init(session_id: String, cwd: String, hook_event_name: String, tool_name: String? = nil, tool_input: JSONValue? = nil, notification_type: String? = nil, reason: String? = nil, permission_mode: String? = nil, last_assistant_message: String? = nil, session_name: String? = nil, _ag_term_program: String? = nil, _ag_iterm_session_id: String? = nil, _ag_tmux: String? = nil, _ag_tmux_pane: String? = nil, _ag_kitty_window_id: String? = nil, _ag_tty: String? = nil) {
        self.session_id = session_id
        self.cwd = cwd
        self.hook_event_name = hook_event_name
        self.tool_name = tool_name
        self.tool_input = tool_input
        self.notification_type = notification_type
        self.reason = reason
        self.permission_mode = permission_mode
        self.last_assistant_message = last_assistant_message
        self.session_name = session_name
        self._ag_term_program = _ag_term_program
        self._ag_iterm_session_id = _ag_iterm_session_id
        self._ag_tmux = _ag_tmux
        self._ag_tmux_pane = _ag_tmux_pane
        self._ag_kitty_window_id = _ag_kitty_window_id
        self._ag_tty = _ag_tty
    }

    static func test(sessionId: String, cwd: String, eventName: String, toolName: String? = nil) -> HookPayload {
        HookPayload(session_id: sessionId, cwd: cwd, hook_event_name: eventName, tool_name: toolName)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session_id = try container.decode(String.self, forKey: .session_id)
        cwd = try container.decode(String.self, forKey: .cwd)
        hook_event_name = try container.decode(String.self, forKey: .hook_event_name)
        tool_name = try container.decodeIfPresent(String.self, forKey: .tool_name)
        tool_input = try container.decodeIfPresent(JSONValue.self, forKey: .tool_input)
        notification_type = try container.decodeIfPresent(String.self, forKey: .notification_type)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        permission_mode = try container.decodeIfPresent(String.self, forKey: .permission_mode)
        last_assistant_message = try container.decodeIfPresent(String.self, forKey: .last_assistant_message)
        session_name = try container.decodeIfPresent(String.self, forKey: .session_name)
        _ag_term_program = try container.decodeIfPresent(String.self, forKey: ._ag_term_program)
        _ag_iterm_session_id = try container.decodeIfPresent(String.self, forKey: ._ag_iterm_session_id)
        _ag_tmux = try container.decodeIfPresent(String.self, forKey: ._ag_tmux)
        _ag_tmux_pane = try container.decodeIfPresent(String.self, forKey: ._ag_tmux_pane)
        _ag_kitty_window_id = try container.decodeIfPresent(String.self, forKey: ._ag_kitty_window_id)
        _ag_tty = try container.decodeIfPresent(String.self, forKey: ._ag_tty)
    }
}

/// Flexible JSON value type for arbitrary tool_input fields
enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }

    /// Convenience: extract a string value from an object by key
    subscript(key: String) -> String? {
        if case .object(let obj) = self, case .string(let val) = obj[key] { return val }
        return nil
    }

    /// Convenience: extract a nested JSONValue from an object by key
    subscript(jsonKey key: String) -> JSONValue? {
        if case .object(let obj) = self { return obj[key] }
        return nil
    }

    /// Convenience: extract an array from an object by key
    var asArray: [JSONValue]? {
        if case .array(let arr) = self { return arr }
        return nil
    }
}
