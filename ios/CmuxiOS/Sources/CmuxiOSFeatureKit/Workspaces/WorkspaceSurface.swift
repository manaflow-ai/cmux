public import Foundation

/// One tab of a pane as the owner reports it: arrangement and status only,
/// never terminal bytes.
public struct WorkspaceSurface: Identifiable, Hashable, Sendable {
    /// The daemon public id (`tab_...`).
    public var id: String
    public var kind: WorkspaceSurfaceKind
    public var title: String
    /// The session host's terminal (`term_...`) for terminal and agent tabs.
    public var terminalID: String?
    public var url: URL?
    public var status: WorkspaceStatus
    public var unreadCount: Int
    /// The last meaningful output line or agent message, when the host sends it.
    public var preview: String?

    public init(
        id: String, kind: WorkspaceSurfaceKind, title: String, terminalID: String? = nil, url: URL? = nil,
        status: WorkspaceStatus = .idle, unreadCount: Int = 0, preview: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.terminalID = terminalID
        self.url = url
        self.status = status
        self.unreadCount = unreadCount
        self.preview = preview
    }
}
