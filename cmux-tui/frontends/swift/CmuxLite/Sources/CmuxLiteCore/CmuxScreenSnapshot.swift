import Foundation

/// An immutable screen entry and recursive visible pane layout.
public struct CmuxScreenSnapshot: Sendable, Equatable {
    /// The server-owned screen identifier.
    public let id: UInt64

    /// The server's active pane, used only to initialize local focus.
    public let activePane: UInt64?

    /// The server's zoomed pane, when the visible layout is reduced to one leaf.
    public let zoomedPane: UInt64?

    /// The render-ready visible pane tree.
    public let layout: CmuxPaneLayoutView

    /// Pane snapshots keyed by their identifiers at the call site.
    public let panes: [CmuxPaneSnapshot]

    /// Creates a screen snapshot.
    /// - Parameters:
    ///   - id: The server-owned screen identifier.
    ///   - activePane: The server's active pane, when valid.
    ///   - zoomedPane: The server's zoomed pane, when present.
    ///   - layout: The visible recursive pane layout.
    ///   - panes: Pane and tab snapshots.
    public init(
        id: UInt64,
        activePane: UInt64?,
        zoomedPane: UInt64?,
        layout: CmuxPaneLayoutView,
        panes: [CmuxPaneSnapshot]
    ) {
        self.id = id
        self.activePane = activePane
        self.zoomedPane = zoomedPane
        self.layout = layout
        self.panes = panes
    }

    /// The active pane's snapshot, retained as a compatibility convenience.
    public var activePaneSnapshot: CmuxPaneSnapshot? {
        panes.first(where: { $0.id == activePane }) ?? panes.first
    }

    /// The active pane identifier, retained for the round-3 single-pane API.
    public var pane: UInt64? {
        activePaneSnapshot?.id
    }

    /// The active pane's active tab index.
    public var activeTab: Int? {
        activePaneSnapshot?.activeTab
    }

    /// The active pane's tabs.
    public var tabs: [CmuxTabSnapshot] {
        activePaneSnapshot?.tabs ?? []
    }
}
