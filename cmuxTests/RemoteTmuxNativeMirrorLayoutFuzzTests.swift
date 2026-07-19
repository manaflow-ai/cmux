import CmuxRemoteSession
import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Deterministic seedable RNG (SplitMix64): every failure reproduces from
/// the seed + trial printed in the assertion message.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Seeded fuzz of the native mirror sizing pipeline, end to end and pure:
/// claim a client grid for a random container (`clientGrid`), assign the
/// claimed cells across a random tree the way tmux does, then run the exact
/// divider walk the mirror applies (`RemoteTmuxNativeSplitLayoutPlanner.plan`) and
/// derive each pane's rendered grid from its outer size the way the terminal
/// surface does. Every pane must render AT LEAST its assigned span — one
/// column short means every full-width line in that pane wraps, which is the
/// live regression this suite pins down (proportional divider fractions
/// starve the deepest panes of a near-exact container).
@Suite struct RemoteTmuxNativeMirrorLayoutFuzzTests {
    private static let seeds: [UInt64] = [
        0x1, 0x2A, 0xBEEF, 0xC0FFEE,
        0xDEAD10CC, 0xFAB1E5, 0x7209, 0x424242,
    ]

    @Test(arguments: seeds)
    func everyPaneRendersAtLeastItsAssignedSpan(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed)

        // The minimum-cells guard below skips regimes whose claim came out
        // too small to assign. That guard exists for pathological metric
        // draws only — containers are built at least four cells above the
        // minimum on each axis — so if most regimes stop executing, the
        // generator or the claim collapsed and the suite would otherwise
        // pass green while testing nothing.
        var executedRegimes = 0

        for trial in 0..<80 {
            let scale: CGFloat = Self.draw(2, using: &rng) == 0 ? 1 : 2
            let cellWidthPx = 7 + Self.draw(18, using: &rng)
            let cellHeightPx = 14 + Self.draw(30, using: &rng)
            let padWidthPx = Self.draw(10, using: &rng)
            let padHeightPx = Self.draw(4, using: &rng)
            let metrics = RemoteTmuxNativeLayoutMetrics(
                cellSize: CGSize(
                    width: CGFloat(cellWidthPx) / scale,
                    height: CGFloat(cellHeightPx) / scale
                ),
                surfacePadding: CGSize(
                    width: CGFloat(padWidthPx) / scale,
                    height: CGFloat(padHeightPx) / scale
                ),
                tabBarHeight: CGFloat(24 + Self.draw(8, using: &rng)),
                dividerThickness: CGFloat(1 + Self.draw(2, using: &rng))
            )

            let paneCount = 2 + Self.draw(7, using: &rng)
            var nextPaneId = 1
            let shape = Self.randomShape(
                paneCount: paneCount,
                nextPaneId: &nextPaneId,
                depth: 0,
                previousAxis: nil,
                using: &rng
            )
            let structure = Self.placeholderNode(shape)

            // Two container regimes per trial: a loose one (random spare
            // beyond the claim), and the killer case — the tight container
            // whose claim consumes it exactly, leaving no spare to hide
            // rounding in.
            let overhead = metrics.residual(of: structure)
            let minimum = Self.minimumCells(shape, minLeaf: 2)
            let cols = max(minimum.cols, RemoteTmuxMirrorGeometry.minCols)
                + 4 + Self.draw(100, using: &rng)
            let rows = max(minimum.rows, RemoteTmuxMirrorGeometry.minRows)
                + 4 + Self.draw(50, using: &rng)
            let paddedSize = CGSize(
                width: CGFloat(cols) * metrics.cellSize.width + overhead.width,
                height: CGFloat(rows) * metrics.cellSize.height + overhead.height
            )
            let tightSize = try #require(Self.tightContainer(
                startingAt: paddedSize,
                layout: structure,
                metrics: metrics,
                scale: scale
            ))
            let looseSize = CGSize(
                width: tightSize.width + CGFloat(Self.draw(Int(metrics.cellSize.width), using: &rng)),
                height: tightSize.height + CGFloat(Self.draw(Int(metrics.cellSize.height), using: &rng))
            )

            // Regimes: tight/loose assign exactly what the claim allows; the
            // over-constrained pair assigns ONE MORE cell than the claim on a
            // single axis — tmux really does that transiently (a claim racing
            // a structure change, a co-attached client) — and the invariants
            // are that the overloaded axis degrades EVENLY (no pane loses
            // more than one cell) while the other axis stays exact
            // everywhere. This is the regime that catches fit-failure on one
            // axis silently turning the whole subtree proportional, and a
            // shortfall being dumped on a single trailing pane.
            for (regime, container, extraCols, extraRows) in [
                (regime: "tight", container: tightSize, extraCols: 0, extraRows: 0),
                (regime: "loose", container: looseSize, extraCols: 0, extraRows: 0),
                (regime: "overRows", container: tightSize, extraCols: 0, extraRows: 1),
                (regime: "overCols", container: tightSize, extraCols: 1, extraRows: 0),
            ] {
                let claim = try #require(
                    metrics.clientGrid(layout: structure, contentSize: container)
                )
                guard claim.columns >= minimum.cols, claim.rows >= minimum.rows else { continue }
                executedRegimes += 1
                let layout = Self.assign(
                    shape,
                    cols: claim.columns + extraCols,
                    rows: claim.rows + extraRows,
                    x: 0,
                    y: 0,
                    using: &rng
                )
                let context = "seed=0x\(String(seed, radix: 16)) trial=\(trial) regime=\(regime)"
                    + " shape=\(Self.describe(layout)) container=\(Int(container.width))x\(Int(container.height))"
                    + " claim=\(claim.columns)x\(claim.rows)"
                    + " cellPx=\(cellWidthPx)x\(cellHeightPx) padPx=\(padWidthPx)x\(padHeightPx)"
                    + " scale=\(Int(scale)) divider=\(metrics.dividerThickness) tabBar=\(metrics.tabBarHeight)"

                let measured = RemoteTmuxNativeMeasuredSplitTree(
                    tree: RemoteTmuxNativeSplitTree(layout: layout),
                    metrics: metrics
                )
                let planner = RemoteTmuxNativeSplitLayoutPlanner(metrics: metrics)
                let plan = planner.plan(
                    tree: measured,
                    parentSize: container
                )
                let outers = planner.outerSizes(of: plan)

                for leaf in Self.leaves(of: layout) {
                    guard case .pane(let paneId) = leaf.content else { continue }
                    let outer = try #require(
                        outers[paneId],
                        "plan dropped pane \(paneId): \(context)"
                    )
                    // What the terminal surface derives from the pane's
                    // outer size, in the renderer's own arithmetic: view
                    // frames land on whole device pixels, and the renderer
                    // floors the padded INTEGER pixel budget to whole cells
                    // — no float epsilon, or the suite would pass boundary
                    // cases the real surface fails.
                    let outerWidthPx = Int((outer.width * scale).rounded())
                    let surfaceHeightPx = Int(
                        ((outer.height - metrics.tabBarHeight) * scale).rounded()
                    )
                    let renderedCols = (outerWidthPx - padWidthPx) / cellWidthPx
                    let renderedRows = (surfaceHeightPx - padHeightPx) / cellHeightPx
                    // An over-assigned axis cannot fit by definition; the
                    // guarantees are that the OTHER axis is untouched by it,
                    // and the overloaded axis spreads its one-cell shortfall
                    // evenly — no pane loses more than one cell.
                    if extraCols == 0 {
                        #expect(
                            renderedCols >= leaf.width,
                            "pane \(paneId) renders \(renderedCols) cols < assigned \(leaf.width) — wraps: \(context)"
                        )
                    } else {
                        #expect(
                            renderedCols >= leaf.width - 1,
                            "pane \(paneId) renders \(renderedCols) cols, assigned \(leaf.width) — over-assignment dumped on one pane: \(context)"
                        )
                    }
                    if extraRows == 0 {
                        #expect(
                            renderedRows >= leaf.height,
                            "pane \(paneId) renders \(renderedRows) rows < assigned \(leaf.height): \(context)"
                        )
                    } else {
                        #expect(
                            renderedRows >= leaf.height - 1,
                            "pane \(paneId) renders \(renderedRows) rows, assigned \(leaf.height) — over-assignment dumped on one pane: \(context)"
                        )
                    }
                    // No surplus ceiling on purpose. Surplus beyond the
                    // assigned span is blank margin, and it is legitimate in
                    // two shapes: reserved slack a full-span pane still
                    // physically covers (about a cell), and fill-axis room a
                    // pane inherits when it shares a row/column with a
                    // chrome-heavier sibling stack (one tab bar per stacked
                    // pane). Runaway growth cannot happen in this walk at
                    // all — every split partitions its parent's extent, so
                    // sizes conserve by construction. Runaway requires the
                    // LIVE loop (render feeding the measured container,
                    // container feeding the claim), which is what the
                    // closed-loop convergence coverage is for.
                }
            }
        }
        #expect(
            executedRegimes >= 100,
            "only \(executedRegimes)/320 regimes executed — generator or claim collapsed"
        )
    }

    /// Removes every spare device pixel without crossing into a smaller client claim.
    private static func tightContainer(
        startingAt initial: CGSize,
        layout: RemoteTmuxLayoutNode,
        metrics: RemoteTmuxNativeLayoutMetrics,
        scale: CGFloat
    ) -> CGSize? {
        guard let claim = metrics.clientGrid(layout: layout, contentSize: initial) else {
            return nil
        }
        let step = 1 / scale
        var size = initial
        while size.width - step > 1 {
            var candidate = size
            candidate.width -= step
            guard metrics.clientGrid(layout: layout, contentSize: candidate)?.columns
                    == claim.columns else { break }
            size = candidate
        }
        while size.height - step > 1 {
            var candidate = size
            candidate.height -= step
            guard metrics.clientGrid(layout: layout, contentSize: candidate)?.rows
                    == claim.rows else { break }
            size = candidate
        }
        return size
    }

    // MARK: - Random generation

    private enum Axis {
        case horizontal
        case vertical

        var opposite: Axis {
            switch self {
            case .horizontal: return .vertical
            case .vertical: return .horizontal
            }
        }
    }

    private enum Shape {
        case pane(Int)
        case split(Axis, [Shape])
    }

    private static func draw(_ upperBound: Int, using rng: inout SplitMix64) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(rng.next() % UInt64(upperBound))
    }

    private static func randomShape(
        paneCount: Int,
        nextPaneId: inout Int,
        depth: Int,
        previousAxis: Axis?,
        using rng: inout SplitMix64
    ) -> Shape {
        if paneCount == 1 {
            defer { nextPaneId += 1 }
            return .pane(nextPaneId)
        }
        let axis: Axis
        if let previousAxis {
            axis = previousAxis.opposite
        } else {
            axis = draw(2, using: &rng) == 0 ? .horizontal : .vertical
        }
        let maxChildren = min(4, paneCount)
        let childCount = maxChildren == 2 ? 2 : 2 + draw(maxChildren - 1, using: &rng)
        var remaining = paneCount
        var childCounts: [Int] = []
        for index in 0..<childCount {
            let slotsAfter = childCount - index - 1
            if slotsAfter == 0 {
                childCounts.append(remaining)
            } else {
                let maxForChild = remaining - slotsAfter
                let count = 1 + draw(maxForChild, using: &rng)
                childCounts.append(count)
                remaining -= count
            }
        }
        let children = childCounts.map { count in
            randomShape(
                paneCount: count,
                nextPaneId: &nextPaneId,
                depth: depth + 1,
                previousAxis: axis,
                using: &rng
            )
        }
        return .split(axis, children)
    }

    private static func placeholderNode(_ shape: Shape) -> RemoteTmuxLayoutNode {
        switch shape {
        case .pane(let paneId):
            return RemoteTmuxLayoutNode(width: 1, height: 1, x: 0, y: 0, content: .pane(paneId))
        case .split(let axis, let children):
            let nodes = children.map(placeholderNode)
            return RemoteTmuxLayoutNode(
                width: 1, height: 1, x: 0, y: 0,
                content: axis == .horizontal ? .horizontal(nodes) : .vertical(nodes)
            )
        }
    }

    /// Minimum cols/rows a shape needs so every leaf keeps at least
    /// `minLeaf` cells per axis, with one separator cell between siblings.
    private static func minimumCells(_ shape: Shape, minLeaf: Int) -> (cols: Int, rows: Int) {
        switch shape {
        case .pane:
            return (cols: minLeaf, rows: minLeaf)
        case .split(let axis, let children):
            let mins = children.map { minimumCells($0, minLeaf: minLeaf) }
            let separators = children.count - 1
            if axis == .horizontal {
                return (
                    cols: mins.reduce(0) { $0 + $1.cols } + separators,
                    rows: mins.map(\.rows).max() ?? minLeaf
                )
            }
            return (
                cols: mins.map(\.cols).max() ?? minLeaf,
                rows: mins.reduce(0) { $0 + $1.rows } + separators
            )
        }
    }

    /// Distributes assigned spans across a shape the way tmux lays out a
    /// window: same-axis children split the parent span minus one separator
    /// cell between each pair; cross-axis children inherit the parent span.
    private static func assign(
        _ shape: Shape,
        cols: Int,
        rows: Int,
        x: Int,
        y: Int,
        using rng: inout SplitMix64
    ) -> RemoteTmuxLayoutNode {
        switch shape {
        case .pane(let paneId):
            return RemoteTmuxLayoutNode(
                width: cols, height: rows, x: x, y: y, content: .pane(paneId)
            )
        case .split(let axis, let children):
            let mins = children.map { minimumCells($0, minLeaf: 2) }
            let separators = children.count - 1
            let span = axis == .horizontal ? cols : rows
            let minTotal = mins.reduce(0) { $0 + (axis == .horizontal ? $1.cols : $1.rows) }
            var spare = span - separators - minTotal
            var spans: [Int] = mins.map { axis == .horizontal ? $0.cols : $0.rows }
            while spare > 0 {
                let index = draw(children.count, using: &rng)
                spans[index] += 1
                spare -= 1
            }
            var nodes: [RemoteTmuxLayoutNode] = []
            var cursorX = x
            var cursorY = y
            for (index, child) in children.enumerated() {
                let childCols = axis == .horizontal ? spans[index] : cols
                let childRows = axis == .horizontal ? rows : spans[index]
                nodes.append(assign(
                    child,
                    cols: childCols,
                    rows: childRows,
                    x: cursorX,
                    y: cursorY,
                    using: &rng
                ))
                if axis == .horizontal {
                    cursorX += spans[index] + 1
                } else {
                    cursorY += spans[index] + 1
                }
            }
            return RemoteTmuxLayoutNode(
                width: cols, height: rows, x: x, y: y,
                content: axis == .horizontal ? .horizontal(nodes) : .vertical(nodes)
            )
        }
    }

    private static func leaves(of node: RemoteTmuxLayoutNode) -> [RemoteTmuxLayoutNode] {
        switch node.content {
        case .pane:
            return [node]
        case .horizontal(let children), .vertical(let children):
            return children.flatMap { leaves(of: $0) }
        }
    }

    private static func describe(_ node: RemoteTmuxLayoutNode) -> String {
        switch node.content {
        case .pane(let paneId):
            return "p\(paneId)[\(node.width)x\(node.height)]"
        case .horizontal(let children):
            return "h(" + children.map(describe).joined(separator: ",") + ")"
        case .vertical(let children):
            return "v(" + children.map(describe).joined(separator: ",") + ")"
        }
    }
}
