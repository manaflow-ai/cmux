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

    public init(
        id: String, macID: String, title: String, directory: String, branch: String? = nil,
        tabs: [WorkspaceTab], lastActivityAt: Date, needsAttention: Bool = false
    ) {
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

    public init(id: String, kind: Kind, title: String, subtitle: String? = nil, harness: String? = nil) {
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
