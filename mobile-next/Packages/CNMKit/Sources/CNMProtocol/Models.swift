import Foundation

/// RPCMethod names on the control lane. Requests go phone → host unless noted.
public struct RPCMethod: RawRepresentable, Sendable, Hashable, Codable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let hello: RPCMethod = "host.hello"

    public static let projectList: RPCMethod = "project.list"

    public static let terminalList: RPCMethod = "terminal.list"
    public static let terminalCreate: RPCMethod = "terminal.create"
    public static let terminalAttach: RPCMethod = "terminal.attach"
    public static let terminalDetach: RPCMethod = "terminal.detach"
    public static let terminalResize: RPCMethod = "terminal.resize"
    public static let terminalClose: RPCMethod = "terminal.close"
    public static let terminalRename: RPCMethod = "terminal.rename"
    /// Host → phone notification: `TerminalInfo` changed or exited.
    public static let terminalChanged: RPCMethod = "terminal.changed"

    public static let agentHarnesses: RPCMethod = "agent.harnesses"
    public static let agentList: RPCMethod = "agent.list"
    public static let agentCreate: RPCMethod = "agent.create"
    public static let agentAttach: RPCMethod = "agent.attach"
    public static let agentDetach: RPCMethod = "agent.detach"
    public static let agentPrompt: RPCMethod = "agent.prompt"
    public static let agentCancel: RPCMethod = "agent.cancel"
    public static let agentSetMode: RPCMethod = "agent.set_mode"
    public static let agentSetModel: RPCMethod = "agent.set_model"
    public static let agentPermission: RPCMethod = "agent.permission"
    public static let agentArchive: RPCMethod = "agent.archive"
    /// Host → phone notification: one ACP `session/update`, a permission
    /// request, or a session state change (`AgentEvent`).
    public static let agentEvent: RPCMethod = "agent.event"
    /// Host → phone notification: `AgentSessionInfo` changed.
    public static let agentChanged: RPCMethod = "agent.changed"

    public static let conversationList: RPCMethod = "conversation.list"
    public static let conversationCreate: RPCMethod = "conversation.create"
    public static let conversationMessages: RPCMethod = "conversation.messages"
    public static let conversationSend: RPCMethod = "conversation.send"
    public static let conversationRead: RPCMethod = "conversation.read"
    public static let conversationDelete: RPCMethod = "conversation.delete"
    public static let conversationPin: RPCMethod = "conversation.pin"
    public static let conversationReact: RPCMethod = "conversation.react"
    /// Host → phone notifications.
    public static let conversationMessage: RPCMethod = "conversation.message"
    public static let conversationChanged: RPCMethod = "conversation.changed"
    public static let conversationTyping: RPCMethod = "conversation.typing"
}

// MARK: - Host

public struct HostHello: Sendable, Hashable, Codable {
    public var name: String
    public var version: String
    public var hostID: String
    public var capabilities: [String]
    public var homeDirectory: String

    public init(name: String, version: String, hostID: String, capabilities: [String], homeDirectory: String) {
        self.name = name
        self.version = version
        self.hostID = hostID
        self.capabilities = capabilities
        self.homeDirectory = homeDirectory
    }
}

public struct ProjectInfo: Sendable, Hashable, Codable, Identifiable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var branch: String?
    public var lastUsedAt: Date?

    public init(path: String, name: String, branch: String? = nil, lastUsedAt: Date? = nil) {
        self.path = path
        self.name = name
        self.branch = branch
        self.lastUsedAt = lastUsedAt
    }
}

// MARK: - Terminals

public struct TerminalInfo: Sendable, Hashable, Codable, Identifiable {
    public var id: UInt32
    public var title: String
    public var cwd: String
    public var cols: Int
    public var rows: Int
    public var running: Bool
    public var exitCode: Int32?
    public var createdAt: Date
    public var lastOutputAt: Date?

    public init(
        id: UInt32, title: String, cwd: String, cols: Int, rows: Int, running: Bool,
        exitCode: Int32? = nil, createdAt: Date, lastOutputAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.running = running
        self.exitCode = exitCode
        self.createdAt = createdAt
        self.lastOutputAt = lastOutputAt
    }
}

public struct TerminalCreateParams: Sendable, Hashable, Codable {
    public var cwd: String?
    public var cols: Int
    public var rows: Int
    public var command: String?

    public init(cwd: String? = nil, cols: Int, rows: Int, command: String? = nil) {
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.command = command
    }
}

public struct TerminalSizeParams: Sendable, Hashable, Codable {
    public var id: UInt32
    public var cols: Int
    public var rows: Int

    public init(id: UInt32, cols: Int, rows: Int) {
        self.id = id
        self.cols = cols
        self.rows = rows
    }
}

public struct TerminalIDParams: Sendable, Hashable, Codable {
    public var id: UInt32
    public var title: String?
    public init(id: UInt32, title: String? = nil) {
        self.id = id
        self.title = title
    }
}

// MARK: - Agents

public struct AgentHarness: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var available: Bool
    public var detail: String?

    public init(id: String, name: String, available: Bool, detail: String? = nil) {
        self.id = id
        self.name = name
        self.available = available
        self.detail = detail
    }
}

public struct AgentSessionInfo: Sendable, Hashable, Codable, Identifiable {
    public enum State: String, Sendable, Hashable, Codable {
        case starting, idle, working, awaitingPermission, failed, exited
    }

    public var id: String
    public var harness: String
    public var title: String
    public var cwd: String
    public var state: State
    public var createdAt: Date
    public var updatedAt: Date
    public var preview: String?
    public var modes: [AgentChoice]
    public var currentMode: String?
    public var models: [AgentChoice]
    public var currentModel: String?
    public var archived: Bool

    public init(
        id: String, harness: String, title: String, cwd: String, state: State,
        createdAt: Date, updatedAt: Date, preview: String? = nil,
        modes: [AgentChoice] = [], currentMode: String? = nil,
        models: [AgentChoice] = [], currentModel: String? = nil, archived: Bool = false
    ) {
        self.id = id
        self.harness = harness
        self.title = title
        self.cwd = cwd
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.preview = preview
        self.modes = modes
        self.currentMode = currentMode
        self.models = models
        self.currentModel = currentModel
        self.archived = archived
    }
}

public struct AgentChoice: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var detail: String?

    public init(id: String, name: String, detail: String? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
    }
}

public struct AgentCreateParams: Sendable, Hashable, Codable {
    public var harness: String
    public var cwd: String
    public var prompt: [JSONValue]?

    public init(harness: String, cwd: String, prompt: [JSONValue]? = nil) {
        self.harness = harness
        self.cwd = cwd
        self.prompt = prompt
    }
}

public struct AgentPromptParams: Sendable, Hashable, Codable {
    public var session: String
    /// ACP `ContentBlock`s.
    public var prompt: [JSONValue]

    public init(session: String, prompt: [JSONValue]) {
        self.session = session
        self.prompt = prompt
    }
}

public struct AgentSessionParams: Sendable, Hashable, Codable {
    public var session: String
    public var value: String?

    public init(session: String, value: String? = nil) {
        self.session = session
        self.value = value
    }
}

public struct AgentPermissionParams: Sendable, Hashable, Codable {
    public var session: String
    public var request: String
    /// `nil` cancels the request.
    public var optionID: String?

    public init(session: String, request: String, optionID: String?) {
        self.session = session
        self.request = request
        self.optionID = optionID
    }
}

/// Everything the phone needs to render an agent session after attach.
public struct AgentAttachResult: Sendable, Hashable, Codable {
    public var info: AgentSessionInfo
    public var events: [AgentEvent]

    public init(info: AgentSessionInfo, events: [AgentEvent]) {
        self.info = info
        self.events = events
    }
}

/// One entry of an agent session log, in order (`seq`).
public struct AgentEvent: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// The user's prompt (`payload` = `{prompt: [ContentBlock]}`).
        case userPrompt
        /// An ACP `session/update` `update` object.
        case update
        /// An ACP `session/request_permission` params object plus
        /// `requestID`; open until a `permissionResolved` with that id.
        case permissionRequest
        case permissionResolved
        /// A turn ended (`payload` = `{stopReason}`).
        case turnEnded
        /// A host-side error message (`payload` = `{message}`).
        case error
    }

    public var session: String
    /// Increases by one per raw event. A merged event (streamed text chunks
    /// folded together) carries the seq of its last chunk.
    public var seq: Int
    public var kind: Kind
    public var at: Date
    public var payload: JSONValue

    public init(session: String, seq: Int, kind: Kind, at: Date, payload: JSONValue) {
        self.session = session
        self.seq = seq
        self.kind = kind
        self.at = at
        self.payload = payload
    }
}

// MARK: - Conversations (Chief and agents, iMessage-style)

public struct Participant: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable { case me, chief, agent }

    public var id: String
    public var name: String
    public var kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

public struct ConversationInfo: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var participants: [Participant]
    public var lastMessage: ConversationMessage?
    public var unreadCount: Int
    public var pinned: Bool
    public var updatedAt: Date

    public init(
        id: String, title: String, participants: [Participant], lastMessage: ConversationMessage?,
        unreadCount: Int, pinned: Bool, updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.participants = participants
        self.lastMessage = lastMessage
        self.unreadCount = unreadCount
        self.pinned = pinned
        self.updatedAt = updatedAt
    }
}

public struct ConversationMessage: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var conversation: String
    public var sender: String
    public var text: String
    public var sentAt: Date
    /// Phone-generated id echoed back so the phone can swap its pending
    /// bubble for the delivered one without a jump.
    public var clientID: String?
    public var reactions: [String: String]
    public var readAt: Date?

    public init(
        id: String, conversation: String, sender: String, text: String, sentAt: Date,
        clientID: String? = nil, reactions: [String: String] = [:], readAt: Date? = nil
    ) {
        self.id = id
        self.conversation = conversation
        self.sender = sender
        self.text = text
        self.sentAt = sentAt
        self.clientID = clientID
        self.reactions = reactions
        self.readAt = readAt
    }
}

public struct ConversationSendParams: Sendable, Hashable, Codable {
    public var conversation: String
    public var text: String
    public var clientID: String

    public init(conversation: String, text: String, clientID: String) {
        self.conversation = conversation
        self.text = text
        self.clientID = clientID
    }
}

public struct ConversationIDParams: Sendable, Hashable, Codable {
    public var conversation: String
    public var flag: Bool?
    public var before: Date?
    public var limit: Int?

    public init(conversation: String, flag: Bool? = nil, before: Date? = nil, limit: Int? = nil) {
        self.conversation = conversation
        self.flag = flag
        self.before = before
        self.limit = limit
    }
}

public struct ConversationCreateParams: Sendable, Hashable, Codable {
    public var title: String?
    public var firstMessage: String?
    public var clientID: String?

    public init(title: String? = nil, firstMessage: String? = nil, clientID: String? = nil) {
        self.title = title
        self.firstMessage = firstMessage
        self.clientID = clientID
    }
}

public struct ConversationReactParams: Sendable, Hashable, Codable {
    public var conversation: String
    public var message: String
    /// `nil` removes my reaction.
    public var reaction: String?

    public init(conversation: String, message: String, reaction: String?) {
        self.conversation = conversation
        self.message = message
        self.reaction = reaction
    }
}

public struct ConversationTyping: Sendable, Hashable, Codable {
    public var conversation: String
    public var sender: String
    public var typing: Bool

    public init(conversation: String, sender: String, typing: Bool) {
        self.conversation = conversation
        self.sender = sender
        self.typing = typing
    }
}

/// Dates on the wire are ISO 8601 with fractional seconds.
public extension JSONEncoder {
    static var cnm: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSince1970)
        }
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }
}

public extension JSONDecoder {
    static var cnm: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
