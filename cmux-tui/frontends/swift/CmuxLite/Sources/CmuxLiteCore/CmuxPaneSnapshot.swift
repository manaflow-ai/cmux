import Foundation

/// An immutable pane and tab-strip snapshot rendered by cmux-lite.
public struct CmuxPaneSnapshot: Sendable, Equatable {
    /// The server-owned pane identifier.
    public let id: UInt64

    /// The active tab index reported by the server.
    public let activeTab: Int?

    /// The PTY surface attached for this pane, when available.
    public let activeSurface: UInt64?

    /// Tabs in server order.
    public let tabs: [CmuxTabSnapshot]

    /// Creates a pane snapshot.
    /// - Parameters:
    ///   - id: The server-owned pane identifier.
    ///   - activeTab: The valid active tab index, when present.
    ///   - activeSurface: The active or fallback live PTY surface.
    ///   - tabs: Tabs in server order.
    public init(
        id: UInt64,
        activeTab: Int?,
        activeSurface: UInt64?,
        tabs: [CmuxTabSnapshot]
    ) {
        self.id = id
        self.activeTab = activeTab
        self.activeSurface = activeSurface
        self.tabs = tabs
    }
}
