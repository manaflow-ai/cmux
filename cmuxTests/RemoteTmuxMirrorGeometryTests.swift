import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Property coverage for the feed-forward sizing math
/// (``RemoteTmuxMirrorGeometry``): f (pixels+structure → client cells) and g
/// (assigned layout → exact frames) must be inverses on the split axis, f must
/// be invariant under re-assigns of the same structure, and the edge-rail
/// placement must never accumulate rounding error — the three properties
/// that make the sizing loop-free by construction.
@Suite struct RemoteTmuxMirrorGeometryTests {
    /// The calibrated 2× constants from the Phase 0 sweep (cell 16×34 px,
    /// pad 8×0 px).
    private var geometry: RemoteTmuxMirrorGeometry {
        RemoteTmuxMirrorGeometry(
            cellWidthPx: 16,
            cellHeightPx: 34,
            surfacePadWidthPx: 8,
            surfacePadHeightPx: 0,
            scale: 2
        )
    }

    private func node(
        _ content: RemoteTmuxLayoutContent, w: Int = -1, h: Int = -1
    ) -> RemoteTmuxLayoutNode {
        RemoteTmuxLayoutNode(width: w, height: h, x: 0, y: 0, content: content)
    }

    /// Deterministic pseudo-random generator so failures reproduce.
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Distributes `total` cells among `n` children with every child ≥ `minEach`,
    /// matching tmux's invariant (children sum to parent − separators).
    private func distribute(
        _ total: Int, among n: Int, minEach: Int, using rng: inout SplitMix
    ) -> [Int] {
        var remaining = total - n * minEach
        var parts = [Int](repeating: minEach, count: n)
        for index in 0..<(n - 1) where remaining > 0 {
            let take = Int.random(in: 0...remaining, using: &rng)
            parts[index] += take
            remaining -= take
        }
        parts[n - 1] += remaining
        return parts
    }

    /// A random structural skeleton (dims are placeholders): structure
    /// decisions consume ONLY the rng, never a size, so the same seed always
    /// yields the same shape — the property the invariance test needs.
    private func randomStructure(depth: Int, using rng: inout SplitMix) -> RemoteTmuxLayoutNode {
        if depth >= 3 || Bool.random(using: &rng) {
            return node(.pane(Int.random(in: 0...9999, using: &rng)))
        }
        let horizontal = Bool.random(using: &rng)
        let count = Int.random(in: 2...3, using: &rng)
        let children = (0..<count).map { _ in randomStructure(depth: depth + 1, using: &rng) }
        return node(horizontal ? .horizontal(children) : .vertical(children))
    }

    /// The minimum cols/rows a structure needs at `minLeaf` cells per pane
    /// (separators included) — trials below this budget are skipped.
    private func minimumCells(of tree: RemoteTmuxLayoutNode, minLeaf: Int) -> (cols: Int, rows: Int) {
        switch tree.content {
        case .pane:
            return (minLeaf, minLeaf)
        case let .horizontal(children):
            let mins = children.map { minimumCells(of: $0, minLeaf: minLeaf) }
            return (mins.map(\.cols).reduce(0, +) + children.count - 1, mins.map(\.rows).max() ?? minLeaf)
        case let .vertical(children):
            let mins = children.map { minimumCells(of: $0, minLeaf: minLeaf) }
            return (mins.map(\.cols).max() ?? minLeaf, mins.map(\.rows).reduce(0, +) + children.count - 1)
        }
    }

    /// Assigns `cols`×`rows` onto an existing structure, preserving its shape
    /// exactly and tmux's sum invariant at every split.
    private func assign(
        _ structure: RemoteTmuxLayoutNode, cols: Int, rows: Int, using rng: inout SplitMix
    ) -> RemoteTmuxLayoutNode {
        switch structure.content {
        case let .pane(id):
            return node(.pane(id), w: cols, h: rows)
        case let .horizontal(children):
            let mins = children.map { minimumCells(of: $0, minLeaf: 2).cols }
            var widths = mins
            var spare = cols - (children.count - 1) - mins.reduce(0, +)
            for index in 0..<children.count where spare > 0 {
                let take = index == children.count - 1 ? spare : Int.random(in: 0...spare, using: &rng)
                widths[index] += take
                spare -= take
            }
            let assigned = zip(children, widths).map { assign($0, cols: $1, rows: rows, using: &rng) }
            return node(.horizontal(assigned), w: cols, h: rows)
        case let .vertical(children):
            let mins = children.map { minimumCells(of: $0, minLeaf: 2).rows }
            var heights = mins
            var spare = rows - (children.count - 1) - mins.reduce(0, +)
            for index in 0..<children.count where spare > 0 {
                let take = index == children.count - 1 ? spare : Int.random(in: 0...spare, using: &rng)
                heights[index] += take
                spare -= take
            }
            let assigned = zip(children, heights).map { assign($0, cols: cols, rows: $1, using: &rng) }
            return node(.vertical(assigned), w: cols, h: rows)
        }
    }

    private func leaves(of tree: RemoteTmuxLayoutNode) -> [RemoteTmuxLayoutNode] {
        switch tree.content {
        case .pane: return [tree]
        case let .horizontal(children), let .vertical(children):
            return children.flatMap { leaves(of: $0) }
        }
    }

    @Test func fAndGAreInversesOnTheSplitAxisAcrossRandomTrees() {
        var rng = SplitMix(state: 0xC0FFEE)
        let geo = geometry
        for trial in 0..<200 {
            let pxW = Int.random(in: 700...3000, using: &rng)
            let pxH = Int.random(in: 500...2200, using: &rng)
            var shapeRng = SplitMix(state: UInt64(trial) &* 7919 &+ 13)
            let structure = randomStructure(depth: 0, using: &shapeRng)
            let cells = geo.clientCells(pixelWidth: pxW, pixelHeight: pxH, structure: structure)
            let need = minimumCells(of: structure, minLeaf: 2)
            guard cells.cols >= need.cols, cells.rows >= need.rows else { continue }
            let assigned = assign(structure, cols: cells.cols, rows: cells.rows, using: &rng)
            let frames = geo.frames(
                layout: assigned,
                containerPt: CGSize(width: CGFloat(pxW) / geo.scale, height: CGFloat(pxH) / geo.scale)
            )
            for leaf in leaves(of: assigned) {
                guard case let .pane(id) = leaf.content,
                      let frame = frames.paneFramesPt[id] else {
                    Issue.record("missing frame for a assigned leaf (trial \(trial))")
                    continue
                }
                let widthPx = (frame.width * geo.scale).rounded()
                let heightPx = (frame.height * geo.scale).rounded()
                let needW = CGFloat(leaf.width * geo.cellWidthPx + geo.surfacePadWidthPx)
                let needH = CGFloat(leaf.height * geo.cellHeightPx + geo.surfacePadHeightPx)
                // Split-axis exactness / cross-axis fill: a frame never holds
                // FEWER pixels than its assigned cells need — a one-pixel
                // shortfall renders one column short and wraps every
                // full-width line (the bug class this design kills).
                #expect(widthPx >= needW - 0.5,
                        "trial \(trial) pane \(id): width \(widthPx)px < needed \(needW)px")
                #expect(heightPx >= needH - 0.5,
                        "trial \(trial) pane \(id): height \(heightPx)px < needed \(needH)px")
            }
            for (id, frame) in frames.paneFramesPt {
                #expect(frame.maxX <= CGFloat(pxW) / geo.scale + 0.5, "pane \(id) overflows width")
                #expect(frame.maxY <= CGFloat(pxH) / geo.scale + 0.5, "pane \(id) overflows height")
            }
        }
    }

    @Test func clientCellsIsInvariantUnderReassignmentOfTheSameStructure() {
        var rng = SplitMix(state: 42)
        let geo = geometry
        for trial in 0..<100 {
            var shapeRng = SplitMix(state: UInt64(trial) &* 104_729 &+ 1)
            let structure = randomStructure(depth: 0, using: &shapeRng)
            var rngA = SplitMix(state: UInt64(trial) &* 31 &+ 7)
            var rngB = SplitMix(state: UInt64(trial) &* 63 &+ 11)
            let need = minimumCells(of: structure, minLeaf: 2)
            let assignedA = assign(structure, cols: need.cols + 90, rows: need.rows + 40, using: &rngA)
            let assignedB = assign(structure, cols: need.cols + 17, rows: need.rows + 9, using: &rngB)
            let pxW = Int.random(in: 700...3000, using: &rng)
            let pxH = Int.random(in: 500...2200, using: &rng)
            let a = geo.clientCells(pixelWidth: pxW, pixelHeight: pxH, structure: assignedA)
            let b = geo.clientCells(pixelWidth: pxW, pixelHeight: pxH, structure: assignedB)
            #expect(a.cols == b.cols && a.rows == b.rows,
                    "trial \(trial): f depended on tmux-assigned geometry, not structure")
        }
    }

    @Test func edgeRailsNeverAccumulateDrift() {
        // Twelve side-by-side panes: with width-based (per-pane rounded)
        // placement, half-pixel errors compound to a full cell by the last
        // pane; rails place every edge at the exact cumulative spend. Each
        // frame carries the +1 device-pixel boundary bias (a frame sitting
        // EXACTLY on the quantization boundary loses a column to any
        // half-pixel shaved downstream), so a pane holds [needed, needed+1]
        // pixels — never less, and never a full cell more.
        let geo = geometry
        let panes = (0..<12).map { node(.pane($0), w: 10, h: 40) }
        let tree = node(.horizontal(panes), w: 10 * 12 + 11, h: 40)
        let frames = geo.frames(layout: tree, containerPt: CGSize(width: 1200, height: 700))
        for index in 0..<12 {
            guard let frame = frames.paneFramesPt[index] else {
                Issue.record("missing pane \(index)"); continue
            }
            let widthPx = frame.width * geo.scale
            let needed = CGFloat(10 * geo.cellWidthPx + geo.surfacePadWidthPx)
            #expect(widthPx >= needed - 0.001,
                    "pane \(index): \(widthPx)px < needed \(needed)px — rail drift")
            #expect(widthPx <= needed + 1.001,
                    "pane \(index): \(widthPx)px > needed+1 \(needed + 1)px — bias grew")
        }
    }

    @Test func crossAxisFillsTheParentAllocation() {
        // h[pane, v[a, b]]: the tall left pane FILLS the region height even
        // though its assigned rows would cost less — the dead-band regression
        // the adversarial pass caught in exact-both-axes imposition.
        let geo = geometry
        let tree = node(.horizontal([
            node(.pane(1), w: 40, h: 30),
            node(.vertical([
                node(.pane(2), w: 40, h: 14),
                node(.pane(3), w: 40, h: 15),
            ]), w: 40, h: 30),
        ]), w: 81, h: 30)
        let container = CGSize(width: 800, height: 620)
        let frames = geo.frames(layout: tree, containerPt: container)
        let left = frames.paneFramesPt[1]!
        let bandPt = CGFloat(geo.cellHeightPx) / geo.scale
        #expect(abs(left.height - (container.height - bandPt)) < 0.001,
                "left pane must fill the container below the title band (no dead band), got \(left.height)")
    }

    @Test func clientCellsClampsDegenerateBudgets() {
        let geo = geometry
        let tiny = geo.clientCells(
            pixelWidth: 10, pixelHeight: 8,
            structure: node(.pane(1), w: 1, h: 1)
        )
        #expect(tiny.cols == RemoteTmuxMirrorGeometry.minCols)
        #expect(tiny.rows == RemoteTmuxMirrorGeometry.minRows)
    }

    /// The pane-header regression guard: panes carry NO per-pane vertical
    /// chrome, so a window's row budget must not depend on how deeply one
    /// branch stacks panes. (With the old 24pt header, a 10-pane column cost
    /// the whole window ~14 rows and shallow branches rendered them as a
    /// blank band below their last row.)
    @Test func rowBudgetIsIndependentOfStackingDepth() {
        let geo = geometry
        let single = node(.pane(1))
        let stackedThree = node(.vertical((0..<3).map { node(.pane($0)) }))
        let stackedTen = node(.vertical((0..<10).map { node(.pane($0)) }))
        for (pxW, pxH) in [(1600, 1288), (900, 700), (2800, 2000)] {
            let a = geo.clientCells(pixelWidth: pxW, pixelHeight: pxH, structure: single)
            let b = geo.clientCells(pixelWidth: pxW, pixelHeight: pxH, structure: stackedThree)
            let c = geo.clientCells(pixelWidth: pxW, pixelHeight: pxH, structure: stackedTen)
            #expect(a.rows == b.rows && b.rows == c.rows,
                    "row budget varied with stacking depth: \(a.rows)/\(b.rows)/\(c.rows) at \(pxW)x\(pxH)")
        }
    }

    /// The title band: one cell-high strip across the top of the window —
    /// every window-top pane's header row (all other panes sit under a tmux
    /// separator). Uniform across branches, so it costs exactly one row of
    /// the budget and cannot skew bottom alignment.
    @Test func framesReserveTheTitleBandAndFOmitsItsRow() {
        let geo = geometry
        let tree = node(.pane(1), w: 98, h: 35)
        let container = CGSize(width: 800, height: 620)
        let frames = geo.frames(layout: tree, containerPt: container)
        let bandPt = CGFloat(geo.cellHeightPx) / geo.scale
        let band = frames.dividersPt.first
        #expect(band != nil && abs(band!.minY) < 0.001 && abs(band!.height - bandPt) < 0.001,
                "first strip must be the full-width title band, got \(String(describing: band))")
        let pane = frames.paneFramesPt[1]!
        #expect(abs(pane.minY - bandPt) < 0.001, "pane must start below the band")
        let cells = geo.clientCells(pixelWidth: 1600, pixelHeight: 1240, structure: tree)
        #expect(cells.rows == 1240 / 34 - 1, "rows must exclude the title-band row")
    }

    @Test func chromeFoldMatchesHandComputedNestedTree() {
        // h[pane, v[pane, pane]]: width chrome = pad + pad = 16 (max of
        // the right column is one pane's pad); height chrome = max(pad, 2·pad)
        // = 100 with a synthetic 50px pad.
        let tree = node(.horizontal([
            node(.pane(1)),
            node(.vertical([node(.pane(2)), node(.pane(3))])),
        ]))
        let chrome = RemoteTmuxMirrorGeometry.chromePx(of: tree, padW: 8, padH: 50)
        #expect(chrome.width == 16)
        #expect(chrome.height == 100)
    }
}
