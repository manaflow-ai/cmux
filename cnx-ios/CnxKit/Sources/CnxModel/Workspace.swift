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
        isWorking: Bool = false, hasUnread: Bool = false, colorHex: String? = nil, icon: String? = nil
    ) {
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

    public init(id: String, kind: Kind, title: String, subtitle: String? = nil, harness: String? = nil, url: URL? = nil) {
        self.url = url
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.harness = harness
    }

    public var systemImage: String {
        switch kind {
        case .terminal: "apple.terminal"
        case .browser: "globe"
        case .agent: "sparkle"
        }
    }
}
