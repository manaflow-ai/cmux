import Foundation

public enum AgentSessionStatus: String, OpenStringEnum {
    case idle, running, waiting, error, closed, unknown
    public static var unknownFallback: Self { .unknown }
}

/// An ACP agent session (PROTOCOL §4 `Session`).
public struct AgentSession: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    /// Harness id, see `Harness.id`.
    public var harness: String
    public var model: String?
    public var mode: String?
    public var cwd: String
    public var status: AgentSessionStatus
    public var createdAt: EpochMillis
    public var updatedAt: EpochMillis
    public var unread: Int
    public var preview: String?

    public init(id: String, title: String, harness: String, model: String? = nil, mode: String? = nil, cwd: String,
                status: AgentSessionStatus, createdAt: EpochMillis, updatedAt: EpochMillis, unread: Int = 0, preview: String? = nil) {
        self.id = id; self.title = title; self.harness = harness; self.model = model; self.mode = mode; self.cwd = cwd
        self.status = status; self.createdAt = createdAt; self.updatedAt = updatedAt; self.unread = unread; self.preview = preview
    }
}

public struct NamedOption: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct Harness: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var available: Bool
    public var models: [NamedOption]
    public var modes: [NamedOption]
    public init(id: String, name: String, available: Bool, models: [NamedOption], modes: [NamedOption]) {
        self.id = id; self.name = name; self.available = available; self.models = models; self.modes = modes
    }
}

public struct SlashCommand: Codable, Sendable, Hashable {
    public var name: String
    public var description: String
    public init(name: String, description: String) { self.name = name; self.description = description }
}

/// An attachment on a user prompt. Transcript items carry the metadata only;
/// `agent.prompt` sends `dataBase64`.
public struct PromptAttachment: Codable, Sendable, Hashable {
    public var name: String
    public var mimeType: String
    public var dataBase64: String?
    public init(name: String, mimeType: String, dataBase64: String? = nil) {
        self.name = name; self.mimeType = mimeType; self.dataBase64 = dataBase64
    }
}

// MARK: Transcript

public struct UserTranscriptItem: Codable, Sendable, Hashable {
    public var id: String
    public var text: String
    public var attachments: [PromptAttachment]
    public init(id: String, text: String, attachments: [PromptAttachment] = []) { self.id = id; self.text = text; self.attachments = attachments }

    enum CodingKeys: String, CodingKey { case id, text, attachments }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        attachments = try c.decodeIfPresent([PromptAttachment].self, forKey: .attachments) ?? []
    }
}

/// Markdown text from the agent.
public struct AssistantTranscriptItem: Codable, Sendable, Hashable {
    public var id: String
    public var text: String
    public var streaming: Bool
    public init(id: String, text: String, streaming: Bool = false) { self.id = id; self.text = text; self.streaming = streaming }
}

public struct ThoughtTranscriptItem: Codable, Sendable, Hashable {
    public var id: String
    public var text: String
    public var streaming: Bool
    public var durationMs: Int?
    public init(id: String, text: String, streaming: Bool = false, durationMs: Int? = nil) {
        self.id = id; self.text = text; self.streaming = streaming; self.durationMs = durationMs
    }
}

public enum ToolKind: String, OpenStringEnum {
    case read, edit, execute, search, fetch, delete, think, other
    public static var unknownFallback: Self { .other }
}

public enum ToolStatus: String, OpenStringEnum {
    case pending, running, completed, failed, unknown
    public static var unknownFallback: Self { .unknown }
}

public struct ToolLocation: Codable, Sendable, Hashable {
    public var path: String
    public var line: Int?
    public init(path: String, line: Int? = nil) { self.path = path; self.line = line }
}

public struct FileDiff: Codable, Sendable, Hashable {
    public var path: String
    /// Absent for a newly created file.
    public var oldText: String?
    public var newText: String
    public init(path: String, oldText: String? = nil, newText: String) { self.path = path; self.oldText = oldText; self.newText = newText }
}

public struct ToolCallTranscriptItem: Codable, Sendable, Hashable {
    public var id: String
    public var toolKind: ToolKind
    public var title: String
    public var status: ToolStatus
    public var input: JSONValue?
    public var output: JSONValue?
    public var locations: [ToolLocation]
    public var diff: [FileDiff]?

    public init(id: String, toolKind: ToolKind, title: String, status: ToolStatus, input: JSONValue? = nil,
                output: JSONValue? = nil, locations: [ToolLocation] = [], diff: [FileDiff]? = nil) {
        self.id = id; self.toolKind = toolKind; self.title = title; self.status = status; self.input = input
        self.output = output; self.locations = locations; self.diff = diff
    }

    enum CodingKeys: String, CodingKey { case id, toolKind, title, status, input, output, locations, diff }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        toolKind = try c.decodeIfPresent(ToolKind.self, forKey: .toolKind) ?? .other
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        status = try c.decodeIfPresent(ToolStatus.self, forKey: .status) ?? .unknown
        input = try c.decodeIfPresent(JSONValue.self, forKey: .input)
        output = try c.decodeIfPresent(JSONValue.self, forKey: .output)
        locations = try c.decodeIfPresent([ToolLocation].self, forKey: .locations) ?? []
        diff = try c.decodeIfPresent([FileDiff].self, forKey: .diff)
    }
}

public enum PlanEntryStatus: String, OpenStringEnum {
    case pending, inProgress = "in_progress", completed, unknown
    public static var unknownFallback: Self { .unknown }
}

public struct PlanEntry: Codable, Sendable, Hashable {
    public var content: String
    public var status: PlanEntryStatus
    /// `high`, `medium` or `low`.
    public var priority: String
    public init(content: String, status: PlanEntryStatus, priority: String = "medium") {
        self.content = content; self.status = status; self.priority = priority
    }
}

public struct PlanTranscriptItem: Codable, Sendable, Hashable {
    public var id: String
    public var entries: [PlanEntry]
    public init(id: String, entries: [PlanEntry]) { self.id = id; self.entries = entries }
}

public enum PermissionOptionKind: String, OpenStringEnum {
    case allowOnce = "allow_once", allowAlways = "allow_always", rejectOnce = "reject_once", rejectAlways = "reject_always", unknown
    public static var unknownFallback: Self { .unknown }
}

public struct PermissionOption: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var kind: PermissionOptionKind
    public init(id: String, name: String, kind: PermissionOptionKind) { self.id = id; self.name = name; self.kind = kind }
}

public struct PermissionTranscriptItem: Codable, Sendable, Hashable {
    public var id: String
    public var toolCallId: String
    public var title: String
    public var options: [PermissionOption]
    /// The chosen option id once answered.
    public var resolved: String?
    public init(id: String, toolCallId: String, title: String, options: [PermissionOption], resolved: String? = nil) {
        self.id = id; self.toolCallId = toolCallId; self.title = title; self.options = options; self.resolved = resolved
    }
}

public enum NoticeLevel: String, OpenStringEnum {
    case info, warning, error
    public static var unknownFallback: Self { .info }
}

public struct NoticeTranscriptItem: Codable, Sendable, Hashable {
    public var id: String
    public var level: NoticeLevel
    public var text: String
    public init(id: String, level: NoticeLevel, text: String) { self.id = id; self.level = level; self.text = text }
}

public struct TurnEndTranscriptItem: Codable, Sendable, Hashable {
    public var id: String
    public var stopReason: String
    public var durationMs: Int
    public init(id: String, stopReason: String, durationMs: Int) { self.id = id; self.stopReason = stopReason; self.durationMs = durationMs }
}

/// A transcript item kind this client does not know. The raw JSON is kept so
/// it round-trips and a UI can show a generic fallback.
public struct UnknownTranscriptItem: Sendable, Hashable {
    public var id: String
    public var kind: String
    public var raw: JSONValue
    public init(id: String, kind: String, raw: JSONValue) { self.id = id; self.kind = kind; self.raw = raw }
}

/// One entry in an agent transcript. Items are upserted by `id`.
public enum TranscriptItem: Codable, Sendable, Hashable, Identifiable {
    case user(UserTranscriptItem)
    case assistant(AssistantTranscriptItem)
    case thought(ThoughtTranscriptItem)
    case tool(ToolCallTranscriptItem)
    case plan(PlanTranscriptItem)
    case permission(PermissionTranscriptItem)
    case notice(NoticeTranscriptItem)
    case turnEnd(TurnEndTranscriptItem)
    case unknown(UnknownTranscriptItem)

    public var id: String {
        switch self {
        case .user(let x): x.id
        case .assistant(let x): x.id
        case .thought(let x): x.id
        case .tool(let x): x.id
        case .plan(let x): x.id
        case .permission(let x): x.id
        case .notice(let x): x.id
        case .turnEnd(let x): x.id
        case .unknown(let x): x.id
        }
    }

    public var kind: String {
        switch self {
        case .user: "user"
        case .assistant: "assistant"
        case .thought: "thought"
        case .tool: "tool"
        case .plan: "plan"
        case .permission: "permission"
        case .notice: "notice"
        case .turnEnd: "turnEnd"
        case .unknown(let x): x.kind
        }
    }

    /// True while an assistant or thought item is still receiving text.
    public var isStreaming: Bool {
        switch self {
        case .assistant(let x): x.streaming
        case .thought(let x): x.streaming
        default: false
        }
    }

    private enum KindKey: String, CodingKey { case kind, id }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: KindKey.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "user": self = .user(try UserTranscriptItem(from: decoder))
        case "assistant": self = .assistant(try AssistantTranscriptItem(from: decoder))
        case "thought": self = .thought(try ThoughtTranscriptItem(from: decoder))
        case "tool": self = .tool(try ToolCallTranscriptItem(from: decoder))
        case "plan": self = .plan(try PlanTranscriptItem(from: decoder))
        case "permission": self = .permission(try PermissionTranscriptItem(from: decoder))
        case "notice": self = .notice(try NoticeTranscriptItem(from: decoder))
        case "turnEnd": self = .turnEnd(try TurnEndTranscriptItem(from: decoder))
        default:
            let raw = try JSONValue(from: decoder)
            self = .unknown(UnknownTranscriptItem(id: raw["id"]?.stringValue ?? "", kind: kind, raw: raw))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .user(let x): try x.encode(to: encoder)
        case .assistant(let x): try x.encode(to: encoder)
        case .thought(let x): try x.encode(to: encoder)
        case .tool(let x): try x.encode(to: encoder)
        case .plan(let x): try x.encode(to: encoder)
        case .permission(let x): try x.encode(to: encoder)
        case .notice(let x): try x.encode(to: encoder)
        case .turnEnd(let x): try x.encode(to: encoder)
        case .unknown(let x):
            try x.raw.encode(to: encoder)
            return
        }
        var c = encoder.container(keyedBy: KindKey.self)
        try c.encode(kind, forKey: .kind)
    }
}

// MARK: RPC payloads

public struct HarnessList: Codable, Sendable, Hashable { public var harnesses: [Harness]; public init(harnesses: [Harness]) { self.harnesses = harnesses } }
public struct AgentSessionList: Codable, Sendable, Hashable { public var sessions: [AgentSession]; public init(sessions: [AgentSession]) { self.sessions = sessions } }
public struct AgentSessionResult: Codable, Sendable, Hashable { public var session: AgentSession; public init(session: AgentSession) { self.session = session } }

public struct AgentCreateParams: Codable, Sendable, Hashable {
    public var harness: String
    public var cwd: String?
    public var model: String?
    public var prompt: String?
    public init(harness: String, cwd: String? = nil, model: String? = nil, prompt: String? = nil) {
        self.harness = harness; self.cwd = cwd; self.model = model; self.prompt = prompt
    }
}

public struct AgentSessionRef: Codable, Sendable, Hashable { public var sessionId: String; public init(sessionId: String) { self.sessionId = sessionId } }

public struct AgentHistory: Codable, Sendable, Hashable {
    public var session: AgentSession
    public var items: [TranscriptItem]
    public var commands: [SlashCommand]
    public init(session: AgentSession, items: [TranscriptItem], commands: [SlashCommand]) {
        self.session = session; self.items = items; self.commands = commands
    }
}

public struct AgentPromptParams: Codable, Sendable, Hashable {
    public var sessionId: String
    public var text: String
    public var attachments: [PromptAttachment]?
    public init(sessionId: String, text: String, attachments: [PromptAttachment]? = nil) {
        self.sessionId = sessionId; self.text = text; self.attachments = attachments
    }
}

public struct AgentPermissionParams: Codable, Sendable, Hashable {
    public var sessionId: String; public var itemId: String; public var optionId: String
    public init(sessionId: String, itemId: String, optionId: String) { self.sessionId = sessionId; self.itemId = itemId; self.optionId = optionId }
}

public struct AgentSetModelParams: Codable, Sendable, Hashable {
    public var sessionId: String; public var modelId: String
    public init(sessionId: String, modelId: String) { self.sessionId = sessionId; self.modelId = modelId }
}

public struct AgentSetModeParams: Codable, Sendable, Hashable {
    public var sessionId: String; public var modeId: String
    public init(sessionId: String, modeId: String) { self.sessionId = sessionId; self.modeId = modeId }
}

public struct AgentRenameParams: Codable, Sendable, Hashable {
    public var sessionId: String; public var title: String
    public init(sessionId: String, title: String) { self.sessionId = sessionId; self.title = title }
}

/// `agent.item` event.
public struct AgentItemEvent: Codable, Sendable, Hashable {
    public var sessionId: String
    public var item: TranscriptItem
    public init(sessionId: String, item: TranscriptItem) { self.sessionId = sessionId; self.item = item }
}
