import Foundation

/// The carrier-independent projection consumed by a future multi-pane
/// terminal renderer. `SSHTmuxLayout` is host character-cell geometry; this
/// value keeps that geometry and gives input routing a deterministic answer
/// without opening a channel or selecting a remote pane.
public struct SSHTmuxPaneProjection: Hashable, Sendable {
    public struct Pane: Hashable, Sendable, Identifiable {
        public let id: String
        public let frame: SSHTmuxLayout.Frame
        /// Stable order from the host layout's leaf traversal.
        public let order: Int
        public let isActive: Bool

        public var columns: Int { frame.columns }
        public var rows: Int { frame.rows }

        public func contains(column: Int, row: Int) -> Bool {
            guard column >= frame.column, row >= frame.row else { return false }
            // The layout parser bounds dimensions, and subtracting after the
            // lower-bound checks avoids overflow for hostile caller values.
            return column - frame.column < frame.columns && row - frame.row < frame.rows
        }
    }

    /// The complete host grid. Sibling panes leave their one-cell tmux
    /// divider between these interiors; divider cells route to no pane.
    public let frame: SSHTmuxLayout.Frame
    public let panes: [Pane]
    public let activePaneID: String?

    public static let maximumPanes = SSHTmuxLayout.maximumPanes

    /// Builds a bounded immutable projection. An active id is optional for
    /// snapshots that did not include active-pane metadata, but an unknown id
    /// is refused so input can never be routed to an unlisted pane.
    public init?(layout: SSHTmuxLayout, activePaneID: String? = nil) {
        guard !layout.panes.isEmpty, layout.panes.count <= Self.maximumPanes else { return nil }
        var ids = Set<String>(minimumCapacity: layout.panes.count)
        for pane in layout.panes {
            guard ids.insert(pane.id).inserted else { return nil }
        }
        if let activePaneID, !ids.contains(activePaneID) { return nil }
        self.frame = layout.root.frame
        self.activePaneID = activePaneID
        self.panes = layout.panes.enumerated().map { order, pane in
            Pane(id: pane.id, frame: pane.frame, order: order, isActive: pane.id == activePaneID)
        }
    }

    /// Looks up a host-issued pane id from the validated inventory.
    public func pane(for id: String) -> Pane? {
        panes.first { $0.id == id }
    }

    /// Routes a host-grid cell to its pane interior. tmux divider cells and
    /// points outside the window intentionally return nil.
    public func pane(atColumn column: Int, row: Int) -> Pane? {
        guard frameContains(column: column, row: row) else { return nil }
        return panes.first { $0.contains(column: column, row: row) }
    }

    private func frameContains(column: Int, row: Int) -> Bool {
        guard column >= frame.column, row >= frame.row else { return false }
        return column - frame.column < frame.columns && row - frame.row < frame.rows
    }
}
