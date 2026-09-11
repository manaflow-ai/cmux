import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The pure half of "a machine workspace opens with its own geometry": the daemon's
/// session snapshot (screens carrying `LayoutDocument`s, panes, tabs) becomes the
/// `SurfaceProjectionLayout` the catalog walks. Directions, ratios, tab order, exact
/// remote views, dropped unknowns, collapsed empty panes, and the fail-closed cases.
@Suite struct CloudWorkspaceLayoutTranslatorTests {
    static let machine = SurfaceMachineID.cloud("vivid-newt")

    // MARK: - Fixture

    static func terminal(_ key: String) -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: key),
            title: key,
            detail: nil,
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            port: nil,
            url: nil
        )
    }

    static func browser(_ key: String) -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .browser, key: key),
            title: key,
            detail: "http://localhost:3000",
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            port: 3000,
            url: "http://localhost:3000"
        )
    }

    /// term_a, browser_1, term_b, term_c, term_d are known; term_ghost is not.
    static let resources: [SurfaceResource] = [
        terminal("term_a"), browser("browser_1"), terminal("term_b"), terminal("term_c"), terminal("term_d"),
    ]

    static func leaf(_ pane: String, _ tabs: [String]) -> [String: Any] {
        ["kind": "leaf", "pane_id": pane, "tab_ids": tabs]
    }

    static func split(_ direction: String, _ ratio: Any?, _ first: [String: Any], _ second: [String: Any]) -> [String: Any] {
        var node: [String: Any] = ["kind": "split", "split_id": "split_\(direction)", "direction": direction, "first": first, "second": second]
        if let ratio { node["ratio"] = ratio }
        return node
    }

    static func document(_ root: [String: Any], screen: String = "screen_1") -> [String: Any] {
        ["version": 1, "screen_id": screen, "active_pane_id": "pane_1", "zoomed_pane_id": NSNull(), "root": root]
    }

    /// One workspace, two screens. The focused screen is
    /// `horizontal(0.6){ pane_1[term_a, browser_1] , vertical(0.3){ pane_2[term_b], pane_3[term_c, term_ghost] } }`;
    /// the other screen holds pane_4[term_d].
    static func snapshot(root: [String: Any]? = nil, screens: [[String: Any]]? = nil) -> [String: Any] {
        let mainRoot = root ?? split("horizontal", 0.6, leaf("pane_1", ["tab_a", "tab_b1"]), split("vertical", 0.3, leaf("pane_2", ["tab_b"]), leaf("pane_3", ["tab_c", "tab_ghost"])))
        return [
            "workspaces": [
                ["id": "ws_main", "name": "main", "index": 0, "focused": true],
                ["id": "ws_api", "name": "api", "index": 1, "focused": false],
            ],
            "screens": screens ?? [
                ["id": "screen_2", "workspace_id": "ws_main", "index": 1, "focused": false, "layout": document(leaf("pane_4", ["tab_d"]), screen: "screen_2")],
                ["id": "screen_1", "workspace_id": "ws_main", "index": 0, "focused": true, "layout": document(mainRoot)],
                ["id": "screen_9", "workspace_id": "ws_api", "index": 0, "focused": true, "layout": document(leaf("pane_9", ["tab_9"]), screen: "screen_9")],
            ],
            "panes": [
                ["id": "pane_1", "screen_id": "screen_1"],
                ["id": "pane_2", "screen_id": "screen_1"],
                ["id": "pane_3", "screen_id": "screen_1"],
                ["id": "pane_4", "screen_id": "screen_2"],
                ["id": "pane_9", "screen_id": "screen_9"],
            ],
            "tabs": [
                ["id": "tab_b1", "pane_id": "pane_1", "index": 1, "focused": false, "name": "app", "content_kind": "browser", "content_id": "browser_1"],
                ["id": "tab_a", "pane_id": "pane_1", "index": 0, "focused": true, "name": "agent", "content_kind": "terminal", "content_id": "term_a"],
                ["id": "tab_b", "pane_id": "pane_2", "index": 0, "focused": true, "content_kind": "terminal", "content_id": "term_b"],
                ["id": "tab_ghost", "pane_id": "pane_3", "index": 1, "focused": false, "content_kind": "terminal", "content_id": "term_ghost"],
                ["id": "tab_c", "pane_id": "pane_3", "index": 0, "focused": true, "content_kind": "terminal", "content_id": "term_c"],
                ["id": "tab_d", "pane_id": "pane_4", "index": 0, "focused": true, "content_kind": "terminal", "content_id": "term_d"],
                ["id": "tab_9", "pane_id": "pane_9", "index": 0, "focused": true, "content_kind": "terminal", "content_id": "term_a"],
            ],
            "terminals": [],
            "browsers": [],
            "agents": [],
        ]
    }

    static func translate(_ snapshot: [String: Any], workspace: String = "ws_main") -> SurfaceProjectionLayout? {
        CloudWorkspaceLayoutTranslator.projectionLayout(snapshot: snapshot, machine: machine, workspaceID: workspace, resources: resources)
    }

    static func keys(_ placements: [SurfaceResourcePlacement]) -> [String] { placements.map(\.resource.key) }

    // MARK: - Geometry

    @Test func focusedScreenBecomesTheTreeWithDirectionsRatiosAndTabs() throws {
        let layout = try #require(Self.translate(Self.snapshot()))
        guard case .split(let direction, let ratio, let first, let second) = layout else {
            Issue.record("expected a split at the root, got \(layout)")
            return
        }
        #expect(direction == .right, "daemon `horizontal` is side by side")
        #expect(ratio == 0.6)

        // First pane: the two tabs of pane_1 in daemon tab order (index, not array order),
        // then the other screen's terminal appended as a tab.
        guard case .leaf(let firstPlacements) = first else {
            Issue.record("expected the left half to be one pane, got \(first)")
            return
        }
        #expect(Self.keys(firstPlacements) == ["term_a", "browser_1", "term_d"])
        let agent = try #require(firstPlacements.first)
        #expect(agent.resource == SurfaceResourceID(machine: Self.machine, kind: .terminal, key: "term_a"))
        #expect(agent.remoteTabID == "tab_a")
        #expect(agent.remoteWorkspaceID == "ws_main")
        let appended = try #require(firstPlacements.last)
        #expect(appended.remoteTabID == "tab_d", "other screens' tabs ride along as tabs of the first pane")

        guard case .split(let innerDirection, let innerRatio, let top, let bottom) = second else {
            Issue.record("expected the right half to be a vertical split, got \(second)")
            return
        }
        #expect(innerDirection == .down, "daemon `vertical` is stacked")
        #expect(innerRatio == 0.3)
        #expect(Self.keys(top.placements) == ["term_b"])
        #expect(Self.keys(bottom.placements) == ["term_c"], "a tab whose resource the catalog does not know is dropped")

        #expect(Self.keys(layout.placements) == ["term_a", "browser_1", "term_d", "term_b", "term_c"], "document order")
    }

    @Test func placementsCarryTheExactRemoteView() throws {
        // The remote view is what lets a projected pane rename and reuse the right tab
        // when one terminal is shown in several places; it is built per tab, not per resource.
        let layout = try #require(Self.translate(Self.snapshot()))
        let views = layout.placements.compactMap { placement -> (String, String?, String?)? in
            (placement.resource.key, placement.remoteTabID, placement.remoteWorkspaceID)
        }
        #expect(views.map { $0.1 } == ["tab_a", "tab_b1", "tab_d", "tab_b", "tab_c"])
        #expect(views.allSatisfy { $0.2 == "ws_main" })
    }

    @Test func ratiosAreClampedToWhatALocalDividerAccepts() throws {
        func rootRatio(_ ratio: Any?) throws -> Double {
            let root = Self.split("horizontal", ratio, Self.leaf("pane_1", ["tab_a"]), Self.leaf("pane_2", ["tab_b"]))
            let layout = try #require(Self.translate(Self.snapshot(root: root)))
            guard case .split(_, let value, _, _) = layout else {
                Issue.record("expected a split")
                return -1
            }
            return value
        }
        #expect(try rootRatio(0.02) == 0.1)
        #expect(try rootRatio(0.99) == 0.9)
        #expect(try rootRatio(nil) == 0.5, "a missing ratio means an even split")
        #expect(try rootRatio("wide") == 0.5, "a non-numeric ratio means an even split")
        #expect(try rootRatio(0.25) == 0.25)
    }

    @Test func stackBecomesStackedPanesWithEqualShares() throws {
        let root: [String: Any] = ["kind": "stack", "pane_ids": ["pane_1", "pane_2", "pane_3"], "expanded_pane_id": "pane_2"]
        let layout = try #require(Self.translate(Self.snapshot(root: root)))
        guard case .split(let direction, let ratio, let first, let rest) = layout,
              case .split(let innerDirection, let innerRatio, let middle, let last) = rest else {
            Issue.record("expected two nested splits, got \(layout)")
            return
        }
        #expect(direction == .down && innerDirection == .down)
        #expect(abs(ratio - 1.0 / 3.0) < 0.0001, "the first of three panes takes a third")
        #expect(innerRatio == 0.5, "the remaining two share the rest evenly")
        #expect(Self.keys(first.placements) == ["term_a", "browser_1", "term_d"])
        #expect(Self.keys(middle.placements) == ["term_b"])
        #expect(Self.keys(last.placements) == ["term_c"])
    }

    @Test func viewportColumnsBecomeSideBySideSplitsWeightedByWidth() throws {
        let root: [String: Any] = [
            "kind": "viewport",
            "base_width": 0.5,
            "columns": [
                ["column_id": "split_c1", "width": 0.5, "root": Self.leaf("pane_1", ["tab_a"])],
                ["column_id": "split_c2", "width": 0.25, "root": Self.leaf("pane_2", ["tab_b"])],
                ["column_id": "split_c3", "width": 0.25, "root": Self.leaf("pane_3", ["tab_c"])],
            ],
        ]
        let layout = try #require(Self.translate(Self.snapshot(root: root)))
        guard case .split(let direction, let ratio, _, let rest) = layout,
              case .split(let innerDirection, let innerRatio, _, _) = rest else {
            Issue.record("expected two nested splits, got \(layout)")
            return
        }
        #expect(direction == .right && innerDirection == .right)
        #expect(ratio == 0.5, "the first column takes half of the whole width")
        #expect(innerRatio == 0.5, "the second takes half of what is left")
    }

    // MARK: - Collapsing and fail-closed

    @Test func aPaneWithOnlyUnknownResourcesCollapsesIntoItsSibling() throws {
        let root = Self.split("horizontal", 0.7, Self.leaf("pane_3", ["tab_ghost"]), Self.leaf("pane_2", ["tab_b"]))
        let layout = try #require(Self.translate(Self.snapshot(root: root)))
        // No split survives: the ghost pane is gone and the other screen's tab still lands
        // in the first pane that exists.
        guard case .leaf(let placements) = layout else {
            Issue.record("expected the surviving pane alone, got \(layout)")
            return
        }
        #expect(Self.keys(placements) == ["term_b", "term_d"])
    }

    @Test func leafFallsBackToTheTabsTableWhenTheDocumentListsNoTabs() throws {
        let root = Self.split("vertical", 0.5, Self.leaf("pane_1", []), Self.leaf("pane_2", []))
        let layout = try #require(Self.translate(Self.snapshot(root: root)))
        #expect(Self.keys(layout.placements) == ["term_a", "browser_1", "term_d", "term_b"])
    }

    @Test func nothingUsableYieldsNil() {
        #expect(Self.translate(Self.snapshot(), workspace: "ws_missing") == nil, "unknown workspace")
        #expect(Self.translate(Self.snapshot(screens: [])) == nil, "no screens")
        let noLayout: [[String: Any]] = [["id": "screen_1", "workspace_id": "ws_main", "index": 0, "focused": true]]
        #expect(Self.translate(Self.snapshot(screens: noLayout)) == nil, "an older daemon without layout documents")
        let ghostOnly = Self.leaf("pane_3", ["tab_ghost"])
        #expect(Self.translate(Self.snapshot(root: ghostOnly)) == nil, "every pane empty after dropping unknowns")
    }

    @Test func anUnreadableDocumentIsDiscardedWhole() {
        let sideways = Self.split("diagonal", 0.5, Self.leaf("pane_1", ["tab_a"]), Self.leaf("pane_2", ["tab_b"]))
        #expect(Self.translate(Self.snapshot(root: sideways)) == nil, "unknown split direction")
        let mystery: [String: Any] = ["kind": "carousel", "pane_ids": ["pane_1"]]
        #expect(Self.translate(Self.snapshot(root: mystery)) == nil, "unknown node kind")
        let headless = Self.split("horizontal", 0.5, ["pane_id": "pane_1"], Self.leaf("pane_2", ["tab_b"]))
        #expect(Self.translate(Self.snapshot(root: headless)) == nil, "a node without a kind")
    }

    @Test func aBareRootNodeIsAcceptedInPlaceOfADocument() throws {
        let screens: [[String: Any]] = [
            ["id": "screen_1", "workspace_id": "ws_main", "index": 0, "focused": true, "layout": Self.leaf("pane_1", ["tab_a", "tab_b1"])],
        ]
        let layout = try #require(Self.translate(Self.snapshot(screens: screens)))
        #expect(Self.keys(layout.placements) == ["term_a", "browser_1"])
    }

    @Test func missingPlacementsPreserveGeometryAndDistinctTabs() {
        let resource = SurfaceResourceID(machine: Self.machine, kind: .terminal, key: "shared")
        let first = SurfaceResourcePlacement(resource: resource, remoteWorkspaceID: "workspace", remoteTabID: "tab-a")
        let other = SurfaceResourcePlacement(resource: resource, remoteWorkspaceID: "workspace", remoteTabID: "tab-b")
        let pool = SurfaceResourcePlacement(resource: SurfaceResourceID(machine: Self.machine, kind: .terminal, key: "pool"))
        let tree = SurfaceProjectionLayout.split(
            direction: .down, ratio: 0.3, first: .leaf(placements: [first]), second: .leaf(placements: [other])
        )
        let merged = tree.includingMissingPlacements([first, other, pool, pool])
        #expect(merged == .split(
            direction: .down, ratio: 0.3, first: .leaf(placements: [first, pool]), second: .leaf(placements: [other])
        ))
        #expect(tree.includingMissingPlacements([first, other]) == tree)
        #expect(SurfaceProjectionLayout.leaf(placements: [first]).includingMissingPlacements([first, other]).placements == [first, other])
    }

    @Test func appendingToFirstLeafReachesTheLeftmostPane() {
        let a = SurfaceResourcePlacement(resource: SurfaceResourceID(machine: Self.machine, kind: .terminal, key: "a"))
        let b = SurfaceResourcePlacement(resource: SurfaceResourceID(machine: Self.machine, kind: .terminal, key: "b"))
        let extra = SurfaceResourcePlacement(resource: SurfaceResourceID(machine: Self.machine, kind: .terminal, key: "x"))
        let tree = SurfaceProjectionLayout.split(direction: .right, ratio: 0.5, first: .split(direction: .down, ratio: 0.5, first: .leaf(placements: [a]), second: .leaf(placements: [b])), second: .leaf(placements: [b]))
        #expect(Self.keys(tree.appendingToFirstLeaf([extra]).placements) == ["a", "x", "b", "b"])
        #expect(tree.appendingToFirstLeaf([]) == tree)
    }
}
