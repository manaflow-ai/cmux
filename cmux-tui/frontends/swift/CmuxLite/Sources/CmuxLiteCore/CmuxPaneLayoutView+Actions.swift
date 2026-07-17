import Foundation

public extension CmuxPaneLayoutView {
    /// Picks a pane whose deepest same-axis ancestor is this group.
    /// - Returns: A server-addressable split target, or `nil` when both branches cross that axis.
    func dividerTarget() -> CmuxSplitTarget? {
        guard case let .group(direction, _, first, second) = self else { return nil }
        let pane = first.paneWithoutCrossing(direction)
            ?? second.paneWithoutCrossing(direction)
        return pane.map { CmuxSplitTarget(pane: $0, direction: direction) }
    }

    /// Resolves the current ratio addressed by a server split target.
    /// - Parameter target: The pane and axis used by `set-ratio`.
    /// - Returns: The deepest matching ancestor ratio, when present.
    func ratio(for target: CmuxSplitTarget) -> Double? {
        deepestMatchingSplit(onPathTo: target.pane, direction: target.direction)?.ratio
    }

    /// Resolves a directional keyboard nudge for a pane's deepest matching split.
    /// - Parameters:
    ///   - pane: The locally active pane.
    ///   - direction: The arrow direction.
    ///   - amount: The absolute ratio step, normally `0.05`.
    /// - Returns: A clamped update, or `nil` when the pane has no split on that axis.
    func ratioNudge(
        for pane: UInt64,
        toward direction: CmuxPaneDirection,
        amount: Double = 0.05
    ) -> CmuxRatioNudge? {
        guard amount.isFinite, amount >= 0,
              let group = deepestMatchingGroup(
                onPathTo: pane,
                direction: direction.splitDirection
              ),
              case let .group(_, ratio, _, _) = group,
              let target = group.dividerTarget()
        else { return nil }
        let nextRatio = CmuxSplitRatio(
            clamping: ratio + direction.ratioSign * amount
        ).value
        return CmuxRatioNudge(
            target: target,
            ratio: nextRatio
        )
    }

    private func paneWithoutCrossing(_ direction: CmuxSplitDirection) -> UInt64? {
        switch self {
        case let .pane(pane):
            return pane
        case let .group(groupDirection, _, first, second):
            guard groupDirection != direction else { return nil }
            return first.paneWithoutCrossing(direction)
                ?? second.paneWithoutCrossing(direction)
        }
    }

    private func deepestMatchingSplit(
        onPathTo pane: UInt64,
        direction: CmuxSplitDirection
    ) -> (ratio: Double, depth: Int)? {
        switch self {
        case let .pane(candidate):
            return candidate == pane ? (ratio: .nan, depth: 0) : nil
        case let .group(groupDirection, ratio, first, second):
            guard var descendant = first.deepestMatchingSplit(
                onPathTo: pane,
                direction: direction
            ) ?? second.deepestMatchingSplit(
                onPathTo: pane,
                direction: direction
            ) else { return nil }
            if descendant.ratio.isNaN || (groupDirection == direction && descendant.depth == 0) {
                if groupDirection == direction {
                    return (ratio, 1)
                }
                descendant.depth = 0
                return descendant
            }
            if groupDirection == direction {
                descendant.depth += 1
            }
            return descendant
        }
    }

    private func deepestMatchingGroup(
        onPathTo pane: UInt64,
        direction: CmuxSplitDirection
    ) -> CmuxPaneLayoutView? {
        switch self {
        case let .pane(candidate):
            return candidate == pane ? .pane(candidate) : nil
        case let .group(groupDirection, _, first, second):
            guard let descendant = first.deepestMatchingGroup(
                onPathTo: pane,
                direction: direction
            ) ?? second.deepestMatchingGroup(
                onPathTo: pane,
                direction: direction
            ) else { return nil }
            if case .group = descendant {
                return descendant
            }
            return groupDirection == direction ? self : descendant
        }
    }
}
