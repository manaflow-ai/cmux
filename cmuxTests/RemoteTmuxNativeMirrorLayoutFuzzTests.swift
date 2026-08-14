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
            let minimum = Self.minimumCells(shape, minLeaf: 2)
            let cols = max(minimum.cols, RemoteTmuxMirrorGeometry.minCols)
                + 4 + Self.draw(100, using: &rng)
            let rows = max(minimum.rows, RemoteTmuxMirrorGeometry.minRows)
                + 4 + Self.draw(50, using: &rng)
            let paddedSize = metrics.exactFitSize(columns: cols, rows: rows, layout: structure)
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
                    // outer size. This suite keeps ROUNDED points→pixels:
                    // its tightened containers deliberately park extents at
                    // the claim boundary, where an allocation can sit within
                    // half a device pixel below a cell boundary — the slack
                    // the tightening removed. The shipping surface floors
                    // (`TerminalSurface.pixelDimension`), so the exact-fit
                    // suites below use the shared floor model; the boundary
                    // tolerance here is this suite's own, deliberate.
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

    /// Drives geometry exactly as tmux would across the edge cases and proves
    /// the design's core guarantee: **there is no avenue for growth.**
    ///
    /// The claim is a pure function of the WINDOW, and the rendered content
    /// never exceeds the container. If content can never exceed the container,
    /// then no measurement of the rendered result — even the (rejected)
    /// measured-container feedback the old design used — can ever grow the
    /// claim. This test asserts all three legs: exact claim, content bounded
    /// by the window, and a closed loop that feeds the rendered bounding box
    /// back as the container and confirms the claim never drifts.
    @Test func sizingHasNoAvenueForGrowth() {
        struct Scenario {
            let name: String
            let window: CGSize
            let cellPx: Int
            let padPx: Int
            let tabBar: CGFloat
            let divider: CGFloat
            let scale: CGFloat
            let shape: Shape
            let seed: UInt64
        }
        // Every shape a real tmux window can hand us, at odd cell/pad/scale
        // combinations: a single pane, an even split, a starved 1-cell first
        // pane beside a wide sibling, a deep alternating nest, a wide fan, and
        // a nested mix. These are the layouts that stressed the old design.
        let scenarios: [Scenario] = [
            Scenario(name: "single", window: CGSize(width: 1728, height: 1000),
                     cellPx: 16, padPx: 3, tabBar: 26, divider: 1, scale: 2,
                     shape: .pane(1), seed: 0x11),
            Scenario(name: "even-h", window: CGSize(width: 800, height: 620),
                     cellPx: 16, padPx: 8, tabBar: 30, divider: 1, scale: 2,
                     shape: .split(.horizontal, [.pane(1), .pane(2)]), seed: 0x22),
            Scenario(name: "starved-first", window: CGSize(width: 1728, height: 900),
                     cellPx: 16, padPx: 3, tabBar: 26, divider: 1, scale: 2,
                     shape: .split(.horizontal, [.pane(1), .pane(2)]), seed: 0x33),
            Scenario(name: "deep-nest", window: CGSize(width: 1400, height: 820),
                     cellPx: 15, padPx: 3, tabBar: 24, divider: 2, scale: 2,
                     shape: .split(.vertical, [
                        .split(.horizontal, [.pane(1), .pane(2), .pane(3)]),
                        .split(.horizontal, [.pane(4), .split(.vertical, [.pane(5), .pane(6)])]),
                        .pane(7),
                     ]), seed: 0x44),
            Scenario(name: "wide-fan", window: CGSize(width: 2000, height: 600),
                     cellPx: 9, padPx: 2, tabBar: 28, divider: 1, scale: 1,
                     shape: .split(.horizontal, [.pane(1), .pane(2), .pane(3), .pane(4)]),
                     seed: 0x55),
            Scenario(name: "nested-vh", window: CGSize(width: 1000, height: 1100),
                     cellPx: 17, padPx: 4, tabBar: 30, divider: 1, scale: 2,
                     shape: .split(.horizontal, [
                        .pane(1),
                        .split(.vertical, [.pane(2), .pane(3)]),
                     ]), seed: 0x66),
        ]

        for scenario in scenarios {
            let metrics = RemoteTmuxNativeLayoutMetrics(
                cellSize: CGSize(
                    width: CGFloat(scenario.cellPx) / scenario.scale,
                    height: CGFloat(scenario.cellPx) / scenario.scale
                ),
                surfacePadding: CGSize(
                    width: CGFloat(scenario.padPx) / scenario.scale,
                    height: CGFloat(scenario.padPx) / scenario.scale
                ),
                tabBarHeight: scenario.tabBar,
                dividerThickness: scenario.divider
            )
            let structure = Self.placeholderNode(scenario.shape)
            let window = scenario.window

            // Leg 1: the claim is exactly floor((window − overhead) / cell),
            // and it is a function of the WINDOW only. Overhead is chrome
            // plus the per-pane rail slack the claim charges so whole-point
            // rails can honor every claimed cell.
            guard let claim = metrics.clientGrid(layout: structure, contentSize: window) else {
                Issue.record("\(scenario.name): no claim for a valid window")
                continue
            }
            let overhead = metrics.residual(of: structure)
            let expectCols = max(
                RemoteTmuxMirrorGeometry.minCols,
                Int(((window.width - overhead.width) / metrics.cellSize.width).rounded(.down))
            )
            let expectRows = max(
                RemoteTmuxMirrorGeometry.minRows,
                Int(((window.height - overhead.height) / metrics.cellSize.height).rounded(.down))
            )
            #expect(claim.columns == expectCols, "\(scenario.name): claim cols")
            #expect(claim.rows == expectRows, "\(scenario.name): claim rows")

            // Legs 2 & 3: closed loop. Each turn, tmux assigns a tree at the
            // claim; we render it; we take the rendered bounding box and feed
            // it back as the container the NEXT claim is measured against —
            // exactly the feedback the old design had. The claim must never
            // drift and the content must never exceed the window.
            var rng = SplitMix64(seed: scenario.seed)
            var container = window
            for turn in 0..<40 {
                guard let loopClaim = metrics.clientGrid(layout: structure, contentSize: container) else {
                    Issue.record("\(scenario.name) turn \(turn): no claim")
                    break
                }
                // Leg 3: no drift — the claim never grows past the first.
                #expect(
                    loopClaim.columns <= claim.columns && loopClaim.rows <= claim.rows,
                    "\(scenario.name) turn \(turn): claim grew to \(loopClaim) from \(claim)"
                )
                let tree = Self.assign(
                    scenario.shape,
                    cols: loopClaim.columns, rows: loopClaim.rows,
                    x: 0, y: 0, using: &rng
                )
                let planner = RemoteTmuxNativeSplitLayoutPlanner(metrics: metrics)
                let plan = planner.plan(
                    tree: RemoteTmuxNativeMeasuredSplitTree(
                        tree: RemoteTmuxNativeSplitTree(layout: tree),
                        metrics: metrics
                    ),
                    parentSize: window
                )
                let outers = planner.outerSizes(of: plan)
                #expect(!outers.isEmpty, "\(scenario.name) turn \(turn): plan produced no rects")
                // Leg 2: every rendered pane fits within the window — no pane,
                // and therefore no bounding box, can exert outward pressure.
                var boundW: CGFloat = 0
                var boundH: CGFloat = 0
                for (pane, size) in outers {
                    #expect(
                        size.width <= window.width + 0.5 && size.height <= window.height + 0.5,
                        "\(scenario.name) turn \(turn): pane \(pane) \(size) exceeds window \(window)"
                    )
                    boundW = max(boundW, size.width)
                    boundH = max(boundH, size.height)
                }
                #expect(
                    boundW <= window.width + 0.5 && boundH <= window.height + 0.5,
                    "\(scenario.name) turn \(turn): content bound \(boundW)x\(boundH) exceeds window \(window)"
                )
                // Feed the rendered bound back as the container. Because it is
                // bounded by the window, the next claim cannot grow — the loop
                // is a stable fixed point, which is the whole guarantee.
                container = CGSize(width: max(boundW, 1), height: max(boundH, 1))
            }
        }
    }

    /// The design's end-to-end claim on named, hand-built fixtures:
    /// **a pure function of window size and tmux geometry produces a bonsplit
    /// layout whose every pane renders exactly its tmux-assigned cell span —
    /// no wrap (never fewer cells than assigned) and no growth (never more).**
    ///
    /// Unlike the seeded fuzz above, which asserts the one-sided "at least its
    /// span" no-wrap floor and tolerates the legitimate surplus a pane inherits
    /// from a chrome-heavier cross-axis sibling, this test uses fixtures with
    /// symmetric sibling chrome (every split's children reserve identical
    /// chrome), where the exact-fit window admits no inherited surplus. There
    /// the guarantee is two-sided equality: `rendered == assigned` on both axes
    /// for every pane. Each fixture is a concrete `window X + geometry Y`, so a
    /// failure names the exact shape that drifted.
    @Test func bonsplitLayoutMatchesTmuxGeometryExactly() {
        struct Fixture {
            let name: String
            let cellPx: (w: Int, h: Int)
            let padPx: (w: Int, h: Int)
            let tabBar: CGFloat
            let divider: CGFloat
            let scale: CGFloat
            let tree: RemoteTmuxLayoutNode
        }

        // A left-to-right row of full-height panes: one tmux separator cell
        // between each, all panes the same height, so no pane inherits
        // cross-axis chrome and every width is exact.
        func row(y: Int, height: Int, panes: [(id: Int, w: Int)]) -> RemoteTmuxLayoutNode {
            var nodes: [RemoteTmuxLayoutNode] = []
            var x = 0
            for pane in panes {
                nodes.append(RemoteTmuxLayoutNode(
                    width: pane.w, height: height, x: x, y: y, content: .pane(pane.id)
                ))
                x += pane.w + 1
            }
            let totalW = panes.reduce(0) { $0 + $1.w } + (panes.count - 1)
            return RemoteTmuxLayoutNode(
                width: totalW, height: height, x: 0, y: y, content: .horizontal(nodes)
            )
        }
        // A top-to-bottom stack of full-width panes.
        func column(x: Int, width: Int, panes: [(id: Int, h: Int)]) -> RemoteTmuxLayoutNode {
            var nodes: [RemoteTmuxLayoutNode] = []
            var y = 0
            for pane in panes {
                nodes.append(RemoteTmuxLayoutNode(
                    width: width, height: pane.h, x: x, y: y, content: .pane(pane.id)
                ))
                y += pane.h + 1
            }
            let totalH = panes.reduce(0) { $0 + $1.h } + (panes.count - 1)
            return RemoteTmuxLayoutNode(
                width: width, height: totalH, x: x, y: 0, content: .vertical(nodes)
            )
        }

        // Two equal columns side by side, each a stack of two equal panes — a
        // 2×2 grid whose sibling chrome is symmetric on both axes.
        let colA = column(x: 0, width: 40, panes: [(1, 10), (2, 10)])
        let colB = column(x: 41, width: 40, panes: [(3, 10), (4, 10)])
        let grid = RemoteTmuxLayoutNode(
            width: 81, height: 21, x: 0, y: 0, content: .horizontal([colA, colB])
        )

        let fixtures: [Fixture] = [
            Fixture(name: "row-even", cellPx: (16, 32), padPx: (4, 2), tabBar: 28,
                    divider: 1, scale: 2,
                    tree: row(y: 0, height: 12, panes: [(1, 19), (2, 19), (3, 19)])),
            Fixture(name: "row-starved", cellPx: (9, 18), padPx: (2, 3), tabBar: 26,
                    divider: 1, scale: 1,
                    tree: row(y: 0, height: 20, panes: [(1, 1), (2, 80)])),
            Fixture(name: "col-stack", cellPx: (14, 30), padPx: (6, 4), tabBar: 30,
                    divider: 2, scale: 2,
                    tree: column(x: 0, width: 100, panes: [(1, 8), (2, 8)])),
            Fixture(name: "grid-2x2", cellPx: (16, 32), padPx: (3, 3), tabBar: 24,
                    divider: 1, scale: 2, tree: grid),
        ]

        for fixture in fixtures {
            let metrics = RemoteTmuxNativeLayoutMetrics(
                cellSize: CGSize(
                    width: CGFloat(fixture.cellPx.w) / fixture.scale,
                    height: CGFloat(fixture.cellPx.h) / fixture.scale
                ),
                surfacePadding: CGSize(
                    width: CGFloat(fixture.padPx.w) / fixture.scale,
                    height: CGFloat(fixture.padPx.h) / fixture.scale
                ),
                tabBarHeight: fixture.tabBar,
                dividerThickness: fixture.divider
            )
            let tree = fixture.tree

            // Window X: sized to exactly fit the geometry's total cell span
            // plus chrome. This is the resting window — the size the claim
            // would have asked tmux for, handed straight back.
            let window = metrics.exactFitSize(
                columns: tree.width, rows: tree.height, layout: tree
            )

            // The claim this window produces must be exactly the geometry's
            // total span — the pure transform round-trips.
            guard let claim = metrics.clientGrid(layout: tree, contentSize: window) else {
                Issue.record("\(fixture.name): no claim for a valid window")
                continue
            }
            #expect(claim.columns == tree.width, "\(fixture.name): claim cols \(claim.columns) != \(tree.width)")
            #expect(claim.rows == tree.height, "\(fixture.name): claim rows \(claim.rows) != \(tree.height)")

            // Pure transform: window + geometry → bonsplit plan → per-pane
            // outer sizes.
            let planner = RemoteTmuxNativeSplitLayoutPlanner(metrics: metrics)
            let plan = planner.plan(
                tree: RemoteTmuxNativeMeasuredSplitTree(
                    tree: RemoteTmuxNativeSplitTree(layout: tree),
                    metrics: metrics
                ),
                parentSize: window
            )
            let outers = planner.outerSizes(of: plan)

            for leaf in Self.leaves(of: tree) {
                guard case .pane(let paneId) = leaf.content else { continue }
                guard let outer = outers[paneId] else {
                    Issue.record("\(fixture.name): plan dropped pane \(paneId)")
                    continue
                }
                // Exactly the renderer's own arithmetic (see the fuzz above):
                // frames land on whole device pixels, then the surface floors
                // the padded integer pixel budget to whole cells.
                let (renderedCols, renderedRows) = Self.renderedCells(
                    outer: outer, tabBar: metrics.tabBarHeight, scale: fixture.scale,
                    padPx: fixture.padPx, cellPx: fixture.cellPx
                )
                // No wrap AND no growth: exactly the assigned span, both axes.
                #expect(
                    renderedCols == leaf.width,
                    "\(fixture.name) pane \(paneId): rendered \(renderedCols) cols != assigned \(leaf.width) (outer \(outer.width))"
                )
                #expect(
                    renderedRows == leaf.height,
                    "\(fixture.name) pane \(paneId): rendered \(renderedRows) rows != assigned \(leaf.height) (outer \(outer.height))"
                )
            }
        }
    }

    /// Desk repro of the e2e sweep failure "nested at width 1000": one
    /// full-height pane beside a top/bottom stack (chrome-ASYMMETRIC — the
    /// exact-fit fuzz below only generates symmetric trees, which is how
    /// this hid), in a region that is NOT an exact multiple of the grid.
    /// Planning against the whole region hands the sub-cell remainder to the
    /// stack's trailing pane, which floors onto an extra row. The contract:
    /// the tree renders at its exact-fit size (what the mirror's
    /// renderFrameSize computes), the remainder stays outside as margin, and
    /// at the exact fit every stacked pane renders exactly its span.
    @Test func subCellLeftoverStaysOutsideTheTreeNotInATrailingPane() throws {
        let scale: CGFloat = 2
        let cellPx = (w: 16, h: 34)
        let padPx = (w: 4, h: 2)
        let metrics = RemoteTmuxNativeLayoutMetrics(
            cellSize: CGSize(width: 8, height: 17),
            surfacePadding: CGSize(width: 2, height: 1),
            tabBarHeight: 28,
            dividerThickness: 1
        )
        let left = RemoteTmuxLayoutNode(width: 31, height: 34, x: 0, y: 0, content: .pane(4))
        let stack = RemoteTmuxLayoutNode(
            width: 29, height: 34, x: 32, y: 0,
            content: .vertical([
                RemoteTmuxLayoutNode(width: 29, height: 17, x: 32, y: 0, content: .pane(5)),
                RemoteTmuxLayoutNode(width: 29, height: 16, x: 32, y: 18, content: .pane(6)),
            ])
        )
        let tree = RemoteTmuxLayoutNode(
            width: 61, height: 34, x: 0, y: 0, content: .horizontal([left, stack])
        )

        let exactFit = metrics.exactFitSize(
            columns: tree.width, rows: tree.height, layout: tree
        )
        // A region with just under one cell of leftover on each axis — the
        // worst case the claim's floor can produce. The claim boundary sits
        // at the slack-free chrome, below the slack-inclusive exact fit, so
        // derive the region from the boundary itself: start a cell past the
        // exact fit and walk back until the claim holds the assigned span.
        var region = CGSize(
            width: exactFit.width + metrics.cellSize.width - 0.5,
            height: exactFit.height + metrics.cellSize.height - 0.5
        )
        while let probe = metrics.clientGrid(layout: tree, contentSize: region),
              probe.columns > tree.width {
            region.width -= 1
        }
        while let probe = metrics.clientGrid(layout: tree, contentSize: region),
              probe.rows > tree.height {
            region.height -= 1
        }
        let claim = try #require(metrics.clientGrid(layout: tree, contentSize: region))
        #expect(claim.columns == tree.width)
        #expect(claim.rows == tree.height)

        // ...and the plan runs against the exact fit, never the region.
        let planner = RemoteTmuxNativeSplitLayoutPlanner(metrics: metrics)
        let plan = planner.plan(
            tree: RemoteTmuxNativeMeasuredSplitTree(
                tree: RemoteTmuxNativeSplitTree(layout: tree), metrics: metrics
            ),
            parentSize: exactFit
        )
        let outers = planner.outerSizes(of: plan)
        for (paneId, assigned) in [(5, (cols: 29, rows: 17)), (6, (cols: 29, rows: 16))] {
            let outer = try #require(outers[paneId], "plan dropped pane \(paneId)")
            let rendered = Self.renderedCells(
                outer: outer, tabBar: metrics.tabBarHeight, scale: scale,
                padPx: padPx, cellPx: cellPx
            )
            #expect(rendered.cols == assigned.cols,
                    "pane \(paneId): \(rendered.cols) cols != \(assigned.cols) (outer \(outer.width))")
            #expect(rendered.rows == assigned.rows,
                    "pane \(paneId): \(rendered.rows) rows != \(assigned.rows) (outer \(outer.height))")
        }
        // The full-height pane must never render SHORT (cross-axis fill may
        // exceed its span by the stack's extra chrome; wrap is the failure).
        let leftOuter = try #require(outers[4])
        let leftRendered = Self.renderedCells(
            outer: leftOuter, tabBar: metrics.tabBarHeight, scale: scale,
            padPx: padPx, cellPx: cellPx
        )
        #expect(leftRendered.cols == 31)
        #expect(leftRendered.rows >= 34)
    }

    /// Fuzzes the exact-fit guarantee across the whole chrome-symmetric family
    /// to prove it has no edge cases: random depth, axis, child counts, spans,
    /// cell/pad/scale/divider — always an exact-fit window — and every pane
    /// must render EXACTLY its assigned span on both axes. No wrap, no growth,
    /// no tolerance. A single seed+trial in the message reproduces any failure.
    @Test(arguments: seeds)
    func exactFitHasNoEdgeCases(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed)
        var executed = 0

        for trial in 0..<120 {
            let scale: CGFloat = Self.draw(2, using: &rng) == 0 ? 1 : 2
            let cellWidthPx = 7 + Self.draw(18, using: &rng)
            let cellHeightPx = 14 + Self.draw(30, using: &rng)
            let padWidthPx = Self.draw(10, using: &rng)
            let padHeightPx = Self.draw(5, using: &rng)
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

            // Two-sided exactness has a metric floor: a pane's ~1pt
            // quantization slack must stay under a cell, i.e. cellPx > ~2·scale.
            // Real fonts are far above this (a cell is ≥7px); a ~2pt font at 2×
            // would legitimately grow a cell. Assert the generator stays in
            // range so the guarantee's scope is explicit, not accidental.
            #expect(
                CGFloat(cellWidthPx) > 2 * scale && CGFloat(cellHeightPx) > 2 * scale,
                "generator must keep cellPx > 2·scale or two-sided exactness no longer holds"
            )

            var nextPaneId = 1
            let shape = Self.symmetricShape(
                depth: 1 + Self.draw(3, using: &rng),
                nextPaneId: &nextPaneId,
                previousAxis: nil,
                using: &rng
            )
            let structure = Self.placeholderNode(shape)
            let minimum = Self.minimumCells(shape, minLeaf: 2)
            let cols = max(minimum.cols, RemoteTmuxMirrorGeometry.minCols) + Self.draw(120, using: &rng)
            let rows = max(minimum.rows, RemoteTmuxMirrorGeometry.minRows) + Self.draw(60, using: &rng)

            // Window sized to fit exactly this cell span plus chrome.
            let window = metrics.exactFitSize(columns: cols, rows: rows, layout: structure)
            let claim = try #require(metrics.clientGrid(layout: structure, contentSize: window))
            // Skip only the rare trial where float rounding makes the
            // constructed window claim one cell fewer than intended (then the
            // window is loose for the claim and surplus is legitimate). This
            // is a window-construction artifact, not a sizing edge case.
            guard claim.columns == cols, claim.rows == rows else { continue }
            executed += 1

            let layout = Self.assign(
                shape, cols: claim.columns, rows: claim.rows, x: 0, y: 0, using: &rng
            )
            let context = "seed=0x\(String(seed, radix: 16)) trial=\(trial)"
                + " shape=\(Self.describe(layout)) window=\(Int(window.width))x\(Int(window.height))"
                + " claim=\(claim.columns)x\(claim.rows)"
                + " cellPx=\(cellWidthPx)x\(cellHeightPx) padPx=\(padWidthPx)x\(padHeightPx)"
                + " scale=\(Int(scale)) divider=\(metrics.dividerThickness) tabBar=\(metrics.tabBarHeight)"

            let planner = RemoteTmuxNativeSplitLayoutPlanner(metrics: metrics)
            let plan = planner.plan(
                tree: RemoteTmuxNativeMeasuredSplitTree(
                    tree: RemoteTmuxNativeSplitTree(layout: layout),
                    metrics: metrics
                ),
                parentSize: window
            )
            let outers = planner.outerSizes(of: plan)

            for leaf in Self.leaves(of: layout) {
                guard case .pane(let paneId) = leaf.content else { continue }
                let outer = try #require(outers[paneId], "plan dropped pane \(paneId): \(context)")
                let (renderedCols, renderedRows) = Self.renderedCells(
                    outer: outer, tabBar: metrics.tabBarHeight, scale: scale,
                    padPx: (padWidthPx, padHeightPx), cellPx: (cellWidthPx, cellHeightPx)
                )
                #expect(
                    renderedCols == leaf.width,
                    "pane \(paneId): rendered \(renderedCols) cols != assigned \(leaf.width): \(context)"
                )
                #expect(
                    renderedRows == leaf.height,
                    "pane \(paneId): rendered \(renderedRows) rows != assigned \(leaf.height): \(context)"
                )
            }
        }
        #expect(executed >= 90, "only \(executed)/120 trials executed — generator or claim collapsed")
    }

    /// The drag round trip. While the user drags a divider, bonsplit owns the
    /// pane's width from the mouse and we convert that width to a tmux cell
    /// span (``requestedTmuxSpan``) and send it — tmux does not overwrite the
    /// pane; the design tolerates transient wrap or gaps here. The moment tmux
    /// assigns the requested span and hands control back, the pane must settle
    /// to EXACTLY that span. This proves the settle half: for any drag
    /// position, the cells we send render exactly once tmux is back in control,
    /// so the only inexactness is the transient during the gesture itself.
    @Test(arguments: seeds)
    func dragSettlesExactlyOnceTmuxTakesControl(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed)
        var executed = 0

        for trial in 0..<160 {
            let horizontal = Self.draw(2, using: &rng) == 0
            let orientation: RemoteTmuxSplitOrientation = horizontal ? .horizontal : .vertical
            let scale: CGFloat = Self.draw(2, using: &rng) == 0 ? 1 : 2
            let cellWidthPx = 7 + Self.draw(18, using: &rng)
            let cellHeightPx = 14 + Self.draw(30, using: &rng)
            let padWidthPx = Self.draw(10, using: &rng)
            let padHeightPx = Self.draw(5, using: &rng)
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

            // A two-pane split along the drag axis. The cross axis is full for
            // both panes (symmetric chrome), so the settled fit is exact.
            let shape = Shape.split(
                horizontal ? .horizontal : .vertical, [.pane(1), .pane(2)]
            )
            let structure = Self.placeholderNode(shape)
            let totalCols = max(RemoteTmuxMirrorGeometry.minCols, 24) + Self.draw(120, using: &rng)
            let totalRows = max(RemoteTmuxMirrorGeometry.minRows, 8) + Self.draw(50, using: &rng)
            let window = metrics.exactFitSize(
                columns: totalCols, rows: totalRows, layout: structure
            )
            guard let claim = metrics.clientGrid(layout: structure, contentSize: window),
                  claim.columns == totalCols, claim.rows == totalRows else { continue }

            // The user drags the divider to a random fraction; convert that to
            // the tmux span we send for the first pane, exactly as the mirror's
            // divider-sync does.
            let dragFraction = 0.1 + CGFloat(Self.draw(801, using: &rng)) / 1000.0 // 0.1...0.9
            let firstPane = RemoteTmuxLayoutNode(width: 1, height: 1, x: 0, y: 0, content: .pane(1))
            let parentExtent = horizontal ? window.width : window.height
            let requested = metrics.requestedTmuxSpan(
                first: firstPane,
                orientation: orientation,
                parentExtent: parentExtent,
                dividerPosition: dragFraction
            )
            let totalSpan = horizontal ? totalCols : totalRows
            // tmux gives the first subtree `requested` cells and the second the
            // remainder, minus the one separator cell between them. Skip drags
            // that leave either side below the two-cell floor the assigner uses.
            let secondSpan = totalSpan - requested - 1
            guard requested >= 2, secondSpan >= 2 else { continue }
            executed += 1

            let firstCols = horizontal ? requested : totalCols
            let firstRows = horizontal ? totalRows : requested
            let secondCols = horizontal ? secondSpan : totalCols
            let secondRows = horizontal ? totalRows : secondSpan
            let secondOriginX = horizontal ? requested + 1 : 0
            let secondOriginY = horizontal ? 0 : requested + 1
            let children = [
                RemoteTmuxLayoutNode(
                    width: firstCols, height: firstRows, x: 0, y: 0, content: .pane(1)
                ),
                RemoteTmuxLayoutNode(
                    width: secondCols, height: secondRows,
                    x: secondOriginX, y: secondOriginY, content: .pane(2)
                ),
            ]
            let layout = RemoteTmuxLayoutNode(
                width: totalCols, height: totalRows, x: 0, y: 0,
                content: horizontal ? .horizontal(children) : .vertical(children)
            )
            let context = "seed=0x\(String(seed, radix: 16)) trial=\(trial)"
                + " orientation=\(orientation) drag=\(String(format: "%.3f", dragFraction))"
                + " requested=\(requested) split=\(firstCols)x\(firstRows)|\(secondCols)x\(secondRows)"
                + " cellPx=\(cellWidthPx)x\(cellHeightPx) padPx=\(padWidthPx)x\(padHeightPx) scale=\(Int(scale))"

            let planner = RemoteTmuxNativeSplitLayoutPlanner(metrics: metrics)
            let plan = planner.plan(
                tree: RemoteTmuxNativeMeasuredSplitTree(
                    tree: RemoteTmuxNativeSplitTree(layout: layout),
                    metrics: metrics
                ),
                parentSize: window
            )
            let outers = planner.outerSizes(of: plan)

            for leaf in Self.leaves(of: layout) {
                guard case .pane(let paneId) = leaf.content else { continue }
                let outer = try #require(outers[paneId], "plan dropped pane \(paneId): \(context)")
                let (renderedCols, renderedRows) = Self.renderedCells(
                    outer: outer, tabBar: metrics.tabBarHeight, scale: scale,
                    padPx: (padWidthPx, padHeightPx), cellPx: (cellWidthPx, cellHeightPx)
                )
                #expect(
                    renderedCols == leaf.width,
                    "pane \(paneId): settled \(renderedCols) cols != requested \(leaf.width): \(context)"
                )
                #expect(
                    renderedRows == leaf.height,
                    "pane \(paneId): settled \(renderedRows) rows != requested \(leaf.height): \(context)"
                )
            }
        }
        #expect(executed >= 100, "only \(executed)/160 drags executed — generator or claim collapsed")
    }

    /// The chrome fold exists in two forms that must agree on every node:
    /// the n-ary ``RemoteTmuxNativeLayoutMetrics/residual(of:)`` feeds the
    /// claim and the render frame, and the binary ``joinedResidual`` fold
    /// builds the measured tree's residuals, which feed the plan's ideals
    /// and the drag-end cell conversion. If the two disagree, the plan's
    /// ideals are measured against a container the claim sized with the
    /// other rule, and the difference lands on whichever pane the rail
    /// allocation starves. Both folds credit the ACTUAL coordinate gap
    /// cells read off the assignment, so they must agree for any coordinate
    /// convention — separator columns, title-row gaps, or packed spans.
    @Test(arguments: seeds)
    func binaryResidualFoldAgreesWithTheNaryFold(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed)
        for trial in 0..<60 {
            for titled in [false, true] {
                let scale: CGFloat = Self.draw(2, using: &rng) == 0 ? 1 : 2
                let cellWidthPx = 7 + Self.draw(18, using: &rng)
                let cellHeightPx = 14 + Self.draw(30, using: &rng)
                let metrics = RemoteTmuxNativeLayoutMetrics(
                    cellSize: CGSize(
                        width: CGFloat(cellWidthPx) / scale,
                        height: CGFloat(cellHeightPx) / scale
                    ),
                    surfacePadding: CGSize(
                        width: CGFloat(Self.draw(10, using: &rng)) / scale,
                        height: CGFloat(Self.draw(5, using: &rng)) / scale
                    ),
                    tabBarHeight: CGFloat(24 + Self.draw(8, using: &rng)),
                    dividerThickness: CGFloat(1 + Self.draw(2, using: &rng)),
                    paneTitleRowHeight: titled ? CGFloat(cellHeightPx) / scale : 0
                )
                var nextPaneId = 1
                let shape = Self.randomShape(
                    paneCount: 2 + Self.draw(7, using: &rng),
                    nextPaneId: &nextPaneId,
                    depth: 0,
                    previousAxis: nil,
                    using: &rng
                )
                let minimum = Self.minimumCells(shape, minLeaf: 2, titledRows: titled)
                let layout = Self.assign(
                    shape,
                    cols: minimum.cols + Self.draw(60, using: &rng),
                    rows: minimum.rows + Self.draw(40, using: &rng),
                    x: 0,
                    y: 0,
                    titledRows: titled,
                    using: &rng
                )
                let context = "seed=0x\(String(seed, radix: 16)) trial=\(trial)"
                    + " titled=\(titled ? 1 : 0) shape=\(Self.describe(layout))"
                    + " cellPx=\(cellWidthPx)x\(cellHeightPx)"
                    + " divider=\(metrics.dividerThickness) tabBar=\(metrics.tabBarHeight)"
                Self.expectResidualFoldsAgree(
                    RemoteTmuxNativeMeasuredSplitTree(
                        tree: RemoteTmuxNativeSplitTree(layout: layout),
                        metrics: metrics
                    ),
                    metrics: metrics,
                    context: context
                )
            }
        }
    }

    /// Recursive half of ``binaryResidualFoldAgreesWithTheNaryFold``: every
    /// measured node's stored residual must equal the n-ary fold of its own
    /// layout, to floating-point noise.
    private static func expectResidualFoldsAgree(
        _ tree: RemoteTmuxNativeMeasuredSplitTree,
        metrics: RemoteTmuxNativeLayoutMetrics,
        context: String
    ) {
        let nary = metrics.residual(of: tree.layout)
        #expect(
            abs(tree.residual.width - nary.width) < 0.001
                && abs(tree.residual.height - nary.height) < 0.001,
            "measured residual \(tree.residual) != n-ary fold \(nary) at \(Self.describe(tree.layout)): \(context)"
        )
        if case .split(_, _, _, _, let first, let second) = tree {
            expectResidualFoldsAgree(first, metrics: metrics, context: context)
            expectResidualFoldsAgree(second, metrics: metrics, context: context)
        }
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

    /// A shape whose every split has structurally identical children, so
    /// sibling chrome is symmetric at every level. Under an exact-fit window
    /// this is the family with no cross-axis surplus, where each pane renders
    /// EXACTLY its assigned span on both axes — the family the exactness fuzz
    /// hammers. One child sub-shape is generated per split and cloned across
    /// the siblings (spans still vary freely; only structure is shared).
    private static func symmetricShape(
        depth: Int,
        nextPaneId: inout Int,
        previousAxis: Axis?,
        using rng: inout SplitMix64
    ) -> Shape {
        if depth <= 0 || draw(100, using: &rng) < 35 {
            defer { nextPaneId += 1 }
            return .pane(nextPaneId)
        }
        let axis: Axis = previousAxis?.opposite
            ?? (draw(2, using: &rng) == 0 ? .horizontal : .vertical)
        let count = 2 + draw(2, using: &rng) // 2...3
        let template = symmetricShape(
            depth: depth - 1,
            nextPaneId: &nextPaneId,
            previousAxis: axis,
            using: &rng
        )
        var children: [Shape] = [template]
        for _ in 1..<count {
            children.append(cloneShape(template, nextPaneId: &nextPaneId))
        }
        return .split(axis, children)
    }

    /// Duplicates a shape's structure with fresh pane ids.
    private static func cloneShape(_ shape: Shape, nextPaneId: inout Int) -> Shape {
        switch shape {
        case .pane:
            defer { nextPaneId += 1 }
            return .pane(nextPaneId)
        case .split(let axis, let children):
            return .split(axis, children.map { cloneShape($0, nextPaneId: &nextPaneId) })
        }
    }

    /// Thin adapter over the ONE production points→cells model
    /// (`RemoteTmuxNativeLayoutMetrics.renderedCells`), shared with the
    /// implementation so the tests and the impl cannot drift apart on the
    /// floor-vs-round question. The real cell-level render is separately
    /// pinned end-to-end by the bonsplit+surface integration test.
    private static func renderedCells(
        outer: CGSize,
        tabBar: CGFloat,
        scale: CGFloat,
        padPx: (w: Int, h: Int),
        cellPx: (w: Int, h: Int)
    ) -> (cols: Int, rows: Int) {
        let grid = RemoteTmuxNativeLayoutMetrics.renderedCells(
            outer: outer,
            tabBarHeight: tabBar,
            scale: scale,
            surfacePadPx: (width: padPx.w, height: padPx.h),
            cellPx: (width: cellPx.w, height: cellPx.h)
        )
        return (cols: grid.columns, rows: grid.rows)
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
    /// With `titledRows` on, stacked panes have NO separator row in the SPAN
    /// — the packed convention; the residual reads gaps off the assignment,
    /// so packed and gapped conventions both fold coherently.
    private static func minimumCells(
        _ shape: Shape, minLeaf: Int, titledRows: Bool = false
    ) -> (cols: Int, rows: Int) {
        switch shape {
        case .pane:
            return (cols: minLeaf, rows: minLeaf)
        case .split(let axis, let children):
            let mins = children.map { minimumCells($0, minLeaf: minLeaf, titledRows: titledRows) }
            let separators = children.count - 1
            if axis == .horizontal {
                return (
                    cols: mins.reduce(0) { $0 + $1.cols } + separators,
                    rows: mins.map(\.rows).max() ?? minLeaf
                )
            }
            return (
                cols: mins.map(\.cols).max() ?? minLeaf,
                rows: mins.reduce(0) { $0 + $1.rows } + (titledRows ? 0 : separators)
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
        titledRows: Bool = false,
        using rng: inout SplitMix64
    ) -> RemoteTmuxLayoutNode {
        switch shape {
        case .pane(let paneId):
            return RemoteTmuxLayoutNode(
                width: cols, height: rows, x: x, y: y, content: .pane(paneId)
            )
        case .split(let axis, let children):
            let mins = children.map { minimumCells($0, minLeaf: 2, titledRows: titledRows) }
            let separatorCells = axis == .vertical && titledRows ? 0 : 1
            let separators = (children.count - 1) * separatorCells
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
                    titledRows: titledRows,
                    using: &rng
                ))
                if axis == .horizontal {
                    cursorX += spans[index] + 1
                } else {
                    cursorY += spans[index] + separatorCells
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
