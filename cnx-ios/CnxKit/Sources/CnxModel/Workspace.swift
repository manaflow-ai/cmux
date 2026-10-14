import Foundation

/// A cmux-next workspace on one Mac.
public struct Workspace: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public var macID: String
    public var title: String
    public var directory: String
    public var branch: String?
    public var tabs: [WorkspaceTab]
    public var lastActivityAt: Date
    /// `lastActivityAt` is a real activity time. False for a live workspace
    /// with no activity seen since the phone connected: its time is only when
    /// the phone first listed it, so the list shows no time for it.
    public var hasActivityTime: Bool
    /// The Mac's focus order (higher = focused more recently; cmux-tui
    /// `focused_at`, a sequence, not a time). Orders rows with no activity time.
    public var focusOrder: Int
    /// The tab on screen on the Mac (the active screen's active pane's tab).
    public var activeTabID: String?
    public var needsAttention: Bool
    /// An agent in the workspace is working (row spinner).
    public var isWorking: Bool
    /// Something new arrived since this device last looked (row unread dot).
    public var hasUnread: Bool
    /// The cmux-next workspace color (`#RRGGBB`) and icon (SF Symbol or one emoji).
    public var colorHex: String?
    public var icon: String?

    public init(
        id: String, macID: String, title: String, directory: String, branch: String? = nil,
        tabs: [WorkspaceTab], lastActivityAt: Date, needsAttention: Bool = false,
        isWorking: Bool = false, hasUnread: Bool = false, colorHex: String? = nil, icon: String? = nil,
        hasActivityTime: Bool = true, focusOrder: Int = 0, activeTabID: String? = nil
    ) {
        self.hasActivityTime = hasActivityTime
        self.focusOrder = focusOrder
        self.activeTabID = activeTabID
        self.isWorking = isWorking
        self.hasUnread = hasUnread
        self.colorHex = colorHex
        self.icon = icon
        self.id = id
        self.macID = macID
        self.title = title
        self.directory = directory
        self.branch = branch
        self.tabs = tabs
        self.lastActivityAt = lastActivityAt
        self.needsAttention = needsAttention
    }
}

extension Workspace {
    enum CodingKeys: String, CodingKey {
        case id, macID, title, directory, branch, tabs, lastActivityAt, hasActivityTime, focusOrder, activeTabID
        case needsAttention, isWorking, hasUnread, colorHex, icon
    }

    /// Snapshots saved before a field existed still load (it takes its default).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            macID: try c.decode(String.self, forKey: .macID),
            title: try c.decode(String.self, forKey: .title),
            directory: try c.decode(String.self, forKey: .directory),
            branch: try c.decodeIfPresent(String.self, forKey: .branch),
            tabs: try c.decode([WorkspaceTab].self, forKey: .tabs),
            lastActivityAt: try c.decode(Date.self, forKey: .lastActivityAt),
            needsAttention: try c.decodeIfPresent(Bool.self, forKey: .needsAttention) ?? false,
            isWorking: try c.decodeIfPresent(Bool.self, forKey: .isWorking) ?? false,
            hasUnread: try c.decodeIfPresent(Bool.self, forKey: .hasUnread) ?? false,
            colorHex: try c.decodeIfPresent(String.self, forKey: .colorHex),
            icon: try c.decodeIfPresent(String.self, forKey: .icon),
            hasActivityTime: try c.decodeIfPresent(Bool.self, forKey: .hasActivityTime) ?? false,
            focusOrder: try c.decodeIfPresent(Int.self, forKey: .focusOrder) ?? 0,
            activeTabID: try c.decodeIfPresent(String.self, forKey: .activeTabID)
        )
    }
}

/// One tab inside a workspace.
public struct WorkspaceTab: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case terminal, browser, agent
    }

    public let id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String?
    /// The agent harness for `.agent` tabs (claude, codex, ...).
    public var harness: String?
    /// Browser tabs: the page URL.
    public var url: URL?
    /// What the tab's agent is doing, when it runs one (an agent tab, or a
    /// terminal running Claude or Codex). Nil when idle or unknown.
    public var agentStatus: AgentStatus?
    /// What a `.waiting` agent waits for, when the Mac's acpmux says (agent tabs).
    /// Nil for a terminal agent, whose report says only that it is blocked.
    public var waitingFor: WaitingFor?

    /// An agent's state as the Mac reports it.
    public enum AgentStatus: String, Hashable, Sendable, Codable {
        case working, waiting
    }

    /// What a waiting agent asks the person for.
    public enum WaitingFor: String, Hashable, Sendable, Codable {
        case permission, question
    }

    /// "<Agent> is asking permission", "<Agent> has a question", else "<Agent> is waiting".
    public var waitingPhrase: String {
        switch waitingFor {
        case .permission: "\(agentName) is asking permission"
        case .question: "\(agentName) has a question"
        case nil: "\(agentName) is waiting"
        }
    }

    public init(id: String, kind: Kind, title: String, subtitle: String? = nil, harness: String? = nil, url: URL? = nil,
                agentStatus: AgentStatus? = nil, waitingFor: WaitingFor? = nil) {
        self.url = url
        self.agentStatus = agentStatus
        self.waitingFor = waitingFor
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.harness = harness
    }

    /// Runs an agent (an agent tab, or a terminal with a known harness).
    public var isAgent: Bool { kind == .agent || harness != nil }

    /// "Claude", "Codex", else the harness capitalized, else "Agent".
    public var agentName: String {
        switch harness {
        case "claude": "Claude"
        case "codex": "Codex"
        case let other? where !other.isEmpty: other.prefix(1).uppercased() + other.dropFirst()
        default: "Agent"
        }
    }

    /// What the agent works on, for a status line: the tab's title unless it
    /// is only the agent's name, then its subtitle. Nil when neither says more.
    public var task: String? {
        let title = title.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty, title.caseInsensitiveCompare(agentName) != .orderedSame, title != harness { return title }
        let subtitle = subtitle?.trimmingCharacters(in: .whitespaces) ?? ""
        return subtitle.isEmpty ? nil : subtitle
    }

    public var systemImage: String {
        switch kind {
        case .terminal: "apple.terminal"
        case .browser: "globe"
        case .agent: "sparkle"
        }
    }
}
