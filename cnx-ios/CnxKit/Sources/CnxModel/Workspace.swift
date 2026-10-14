import Foundation

/// A cmux-next workspace on one Mac.
public struct Workspace: Identifiable, Hashable, Sendable {
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

/// One tab inside a workspace.
public struct WorkspaceTab: Identifiable, Hashable, Sendable {
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

    /// An agent's state as the Mac reports it. The Mac does not say whether a
    /// waiting agent asks for a permission or a question.
    public enum AgentStatus: String, Hashable, Sendable {
        case working, waiting
    }

    public init(id: String, kind: Kind, title: String, subtitle: String? = nil, harness: String? = nil, url: URL? = nil,
                agentStatus: AgentStatus? = nil) {
        self.url = url
        self.agentStatus = agentStatus
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
