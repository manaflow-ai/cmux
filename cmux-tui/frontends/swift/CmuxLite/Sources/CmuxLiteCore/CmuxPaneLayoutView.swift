import Foundation

/// A render-ready pane layout with server ratios normalized to safe bounds.
public indirect enum CmuxPaneLayoutView: Sendable, Equatable {
    /// A visible pane leaf.
    case pane(UInt64)

    /// A nested row or column group.
    case group(
        direction: CmuxSplitDirection,
        ratio: Double,
        first: CmuxPaneLayoutView,
        second: CmuxPaneLayoutView
    )

    /// Maps a wire layout to the recursive view tree used by frontends.
    /// - Parameters:
    ///   - layout: The authoritative server layout.
    ///   - zoomedPane: A zoomed pane that replaces the rendered tree, when present.
    public init(layout: CmuxLayout, zoomedPane: UInt64? = nil) {
        if let zoomedPane {
            self = .pane(zoomedPane)
            return
        }
        switch layout {
        case let .leaf(pane):
            self = .pane(pane)
        case let .split(direction, ratio, first, second):
            self = .group(
                direction: direction,
                ratio: CmuxSplitRatio(clamping: ratio).value,
                first: CmuxPaneLayoutView(layout: first),
                second: CmuxPaneLayoutView(layout: second)
            )
        }
    }

    /// Pane identifiers in stable depth-first display order.
    public var paneIDs: [UInt64] {
        switch self {
        case let .pane(pane):
            [pane]
        case let .group(_, _, first, second):
            first.paneIDs + second.paneIDs
        }
    }
}
