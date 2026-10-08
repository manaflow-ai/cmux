import Foundation

/// Coordinates the read-only tmux pane layout that a renderer owns.
///
/// A tmux window can change its split tree while each pane's terminal parser
/// is still live. This value keeps the host-issued pane id as the renderer's
/// identity and turns a layout update into deterministic lifecycle changes.
/// A consumer can therefore keep parser state for an ``SSHTmuxPaneProjection.Pane``
/// whose id survives the update, resize that renderer when its frame changes,
/// and tear down only panes that disappeared. No channel I/O or tmux command
/// is performed here.
public struct SSHTmuxPaneComposition: Hashable, Sendable {
    public typealias Pane = SSHTmuxPaneProjection.Pane

    /// A pane-local input cell selected from the host grid.
    public struct InputTarget: Hashable, Sendable {
        public let paneID: String
        public let column: Int
        public let row: Int

        fileprivate init(paneID: String, column: Int, row: Int) {
            self.paneID = paneID
            self.column = column
            self.row = row
        }
    }

    /// The changed representation of a pane whose host id is still present.
    /// Keeping `previous` lets a renderer resize or move its view without
    /// discarding the parser state associated with `current.id`.
    public struct PaneUpdate: Hashable, Sendable {
        public let previous: Pane
        public let current: Pane

        public var frameChanged: Bool { previous.frame != current.frame }
        public var orderChanged: Bool { previous.order != current.order }
        public var activeStateChanged: Bool { previous.isActive != current.isActive }

        fileprivate init(previous: Pane, current: Pane) {
            self.previous = previous
            self.current = current
        }
    }

    /// Ordered reconciliation operations. Removals follow the old host order;
    /// additions and updates follow the new host order. This makes teardown
    /// happen before a replacement pane is installed and keeps update output
    /// stable across equivalent discovery runs.
    public enum Change: Hashable, Sendable {
        case added(Pane)
        case removed(Pane)
        case updated(PaneUpdate)

        public var paneID: String {
            switch self {
            case .added(let pane), .removed(let pane): pane.id
            case .updated(let update): update.current.id
            }
        }
    }

    /// The latest validated host projection.
    public private(set) var projection: SSHTmuxPaneProjection

    public init(projection: SSHTmuxPaneProjection) {
        self.projection = projection
    }

    /// The current host-ordered panes. The ids are stable renderer keys; an
    /// order or frame change is represented by ``reconcile(to:)``.
    public var panes: [Pane] { projection.panes }

    /// Maps a host-grid cell to pane-local coordinates. Tmux divider cells
    /// and cells outside the root frame return nil, so an input gesture can
    /// never be sent to an arbitrary pane when the split geometry is stale.
    public func inputTarget(atColumn column: Int, row: Int) -> InputTarget? {
        guard let pane = projection.pane(atColumn: column, row: row) else { return nil }
        return InputTarget(paneID: pane.id,
                           column: column - pane.frame.column,
                           row: row - pane.frame.row)
    }

    /// Applies a newer host projection and returns the minimal pane lifecycle
    /// operations needed by a renderer composition. A pane with the same id
    /// is never reported as removed and added: its parser state belongs to the
    /// id and survives frame/order/active-state changes.
    @discardableResult
    public mutating func reconcile(to next: SSHTmuxPaneProjection) -> [Change] {
        // Compare the complete value, not just its pane inventory. The root
        // frame is part of the projection and must be refreshed even when a
        // future projection version carries equal pane data with new root
        // geometry.
        guard projection != next else { return [] }
        let oldPanes = projection.panes
        let nextPanes = next.panes

        let oldByID = Dictionary(uniqueKeysWithValues: oldPanes.map { ($0.id, $0) })
        let nextByID = Dictionary(uniqueKeysWithValues: nextPanes.map { ($0.id, $0) })
        var changes: [Change] = []
        changes.reserveCapacity(oldPanes.count + nextPanes.count)

        for pane in oldPanes where nextByID[pane.id] == nil {
            changes.append(.removed(pane))
        }
        for pane in nextPanes where oldByID[pane.id] == nil {
            changes.append(.added(pane))
        }
        for pane in nextPanes {
            guard let previous = oldByID[pane.id], previous != pane else { continue }
            changes.append(.updated(PaneUpdate(previous: previous, current: pane)))
        }

        projection = next
        return changes
    }
}
