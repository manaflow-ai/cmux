import AppKit
import Bonsplit
import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Dropping a Cloud tree row into a local workspace (#15910): the terminal's pane
/// appears before the machine answers, is adopted in place, and rolls back cleanly.
@MainActor
@Suite(.serialized)
struct CloudSurfaceDropOptimisticTests {
    enum Spot: String, CaseIterable, CustomTestStringConvertible {
        case split, tab
        var testDescription: String { rawValue }
    }

    @Test("A dropped terminal occupies its pane before the machine answers and attaches in place",
          arguments: Spot.allCases)
    func pendingThenAttachedInPlace(spot: Spot) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let d = try DropFixture()
            defer { d.close() }
            d.f.provider.gate = CloudLinkFirstValue<Bool>()
            defer { d.f.provider.gate?.resolve(true) }
            #expect(d.drop(try d.terminalRow("term-one"), at: spot))
            #expect(await d.f.provider.started.result == true)
            // The machine has not answered: the pane already holds the drop spot,
            // has focus, and carries the Cloud identity it will keep.
            let pending = try #require(d.workspace.cloudPendingCreations.values.first)
            #expect(d.workspace.cloudPendingCreations.count == 1)
            #expect(d.workspace.panels.count == d.panelCount + 1)
            #expect(d.workspace.focusedPanelId == pending.panelID)
            switch spot {
            case .tab: #expect(d.workspace.paneId(forPanelId: pending.panelID) == d.pane)
            case .split: #expect(d.workspace.paneId(forPanelId: pending.panelID) != d.pane)
            }
            let projection = try #require(d.catalog.projection(forPanel: pending.panelID))
            #expect(projection.resource == d.terminal("term-one"))
            #expect(projection.remoteWorkspaceID == d.f.remote.id)
            #expect(projection.remoteTabID == "tab-one")

            d.f.provider.gate?.resolve(true)
            try await d.waitUntil { d.workspace.cloudPendingCreations.isEmpty }
            #expect(d.workspace.panels.count == d.panelCount + 1)
            #expect(d.catalog.projections == [projection])
            #expect(d.workspace.focusedPanelId == pending.panelID)
            #expect(d.f.provider.materializations == 1)
        }
    }

    @Test("A failed attach removes only the dropped pane and restores layout and selection",
          arguments: Spot.allCases)
    func failureRollsBack(spot: Spot) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let d = try DropFixture(secondTab: true)
            defer { d.close() }
            d.f.provider.gate = CloudLinkFirstValue<Bool>()
            d.f.provider.failAt = 1
            defer { d.f.provider.gate?.resolve(true) }
            #expect(d.drop(try d.terminalRow("term-one"), at: spot))
            #expect(await d.f.provider.started.result == true)
            #expect(d.workspace.cloudPendingCreations.count == 1)

            d.f.provider.gate?.resolve(true)
            try await d.waitUntil { d.workspace.cloudPendingCreations.isEmpty && d.workspace.panels.count == d.panelCount }
            d.expectOriginalLayout()
            #expect(d.catalog.projections.isEmpty)
            #expect(d.f.provider.remoteCloses == 0)
        }
    }

    @Test("A reply for another tab is stale and rolls the drop back")
    func staleReplyRollsBack() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let d = try DropFixture()
            defer { d.close() }
            d.f.provider.answeredTabID = "tab-two"
            #expect(d.drop(try d.terminalRow("term-one"), at: .split))
            #expect(await d.f.provider.started.result == true)
            try await d.waitUntil { d.workspace.cloudPendingCreations.isEmpty && d.workspace.panels.count == d.panelCount }
            d.expectOriginalLayout()
            #expect(d.catalog.projections.isEmpty)
        }
    }

    @Test("Sign-out rolls back a pending drop and its late answer never resurrects it")
    func signOutRollsBack() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let d = try DropFixture(secondTab: true)
            defer { d.close() }
            d.f.provider.gate = CloudLinkFirstValue<Bool>()
            defer { d.f.provider.gate?.resolve(true) }
            #expect(d.drop(try d.terminalRow("term-one"), at: .tab))
            #expect(await d.f.provider.started.result == true)
            #expect(d.workspace.cloudPendingCreations.count == 1)

            d.catalog.unregister(machine: d.f.provider.machine)
            #expect(d.workspace.cloudPendingCreations.isEmpty)
            d.expectOriginalLayout()

            d.f.provider.gate?.resolve(true)
            for _ in 0..<50 { await Task.yield() }
            d.expectOriginalLayout()
            #expect(d.catalog.projections.isEmpty)
        }
    }

    @Test("Repeated drops of one terminal, pending or attached, keep one pane")
    func repeatedDropsAreIdempotent() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let d = try DropFixture()
            defer { d.close() }
            d.f.provider.gate = CloudLinkFirstValue<Bool>()
            defer { d.f.provider.gate?.resolve(true) }
            let row = try d.terminalRow("term-one")
            #expect(d.drop(row, at: .split))
            #expect(await d.f.provider.started.result == true)
            let pending = try #require(d.workspace.cloudPendingCreations.values.first).panelID

            // Again while it is still connecting: focus returns to the same pane.
            d.workspace.focusPanel(d.original)
            #expect(d.drop(row, at: .tab))
            try await d.waitUntil { d.workspace.focusedPanelId == pending }
            #expect(d.workspace.cloudPendingCreations.count == 1)
            #expect(d.workspace.panels.count == d.panelCount + 1)

            d.f.provider.gate?.resolve(true)
            try await d.waitUntil { d.workspace.cloudPendingCreations.isEmpty }

            // And once it is attached.
            d.workspace.focusPanel(d.original)
            #expect(d.drop(row, at: .split))
            try await d.waitUntil { d.workspace.focusedPanelId == pending }
            #expect(d.workspace.panels.count == d.panelCount + 1)
            #expect(d.catalog.projections.map(\.panelID) == [pending])
            #expect(d.f.provider.materializations == 1)
        }
    }

    @Test("Rolling back one member never hides a sibling from the same drop that attached")
    func partialFailureKeepsAttachedSibling() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let d = try DropFixture(neighborPane: true)
            defer { d.close() }
            d.f.provider.gate = CloudLinkFirstValue<Bool>()
            d.f.provider.failTabID = "tab-two"
            defer { d.f.provider.gate?.resolve(true) }
            #expect(d.drop(try d.f.row(), at: .tab))
            #expect(await d.f.provider.started.result == true)
            let lead = try #require(d.catalog.projections.first { $0.remoteTabID == "tab-one" }).panelID
            let neighbor = try #require(d.neighbor)
            d.workspace.focusPanel(neighbor)

            d.f.provider.gate?.resolve(true)
            try await d.waitUntil { d.workspace.cloudPendingCreations.isEmpty }
            #expect(d.catalog.projections.map(\.panelID) == [lead])
            #expect(d.workspace.bonsplitController.selectedTab(inPane: d.pane)?.id == d.workspace.surfaceIdFromPanelId(lead))
            #expect(d.workspace.focusedPanelId == neighbor)
        }
    }

    @Test("A resource on this Mac is never treated as already open, so its drop still moves it")
    func localResourceIsNeverReused() {
        let catalog = SurfaceCatalog()
        let workspaceID = UUID()
        let local = SurfaceResourceID(machine: .local, kind: .terminal, key: "local-shell")
        let cloud = SurfaceResourceID(machine: .cloud("drop-reuse"), kind: .terminal, key: "term")
        catalog.record(SurfaceProjection(resource: local, workspaceID: workspaceID, panelID: UUID()))
        catalog.record(SurfaceProjection(resource: cloud, workspaceID: workspaceID, panelID: UUID()))
        let lookup: SurfaceCatalog.PaneLookup = { _, _ in "pane" }
        #expect(catalog.openProjection(of: local, remoteView: nil, in: workspaceID, paneLookup: lookup) == nil)
        #expect(catalog.openProjection(of: cloud, remoteView: nil, in: workspaceID, paneLookup: lookup) != nil)
    }

    @Test("A dropped Cloud workspace reserves every terminal before any attach answers")
    func workspaceDropReservesEveryTerminal() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let d = try DropFixture()
            defer { d.close() }
            d.f.provider.gate = CloudLinkFirstValue<Bool>()
            defer { d.f.provider.gate?.resolve(true) }
            #expect(d.drop(try d.f.row(), at: .split))
            #expect(await d.f.provider.started.result == true)
            let reserved = d.workspace.cloudPendingCreations.values.map(\.panelID)
            #expect(reserved.count == 2)
            // The first terminal takes the drop spot; the rest join it as tabs.
            #expect(Set(reserved.map { d.workspace.paneId(forPanelId: $0) }).count == 1)
            #expect(Set(d.catalog.projections.compactMap(\.remoteTabID)) == ["tab-one", "tab-two"])

            d.f.provider.gate?.resolve(true)
            try await d.waitUntil { d.workspace.cloudPendingCreations.isEmpty }
            #expect(Set(d.catalog.projections.map(\.panelID)) == Set(reserved))
            #expect(d.workspace.panels.count == d.panelCount + 2)
        }
    }
}

/// A local workspace beside the Cloud fixture graph (`ws-open`: `term-one`/`tab-one`
/// and `term-two`/`tab-two`), with a provider whose attachment the test releases.
@MainActor
private final class DropFixture {
    let f: CloudWorkspaceRowOpenFixture
    let workspace: Workspace
    let pane: PaneID
    let original: UUID
    let panelCount: Int
    let layout: [String]
    let focused: UUID?
    /// A terminal in a second pane beside the drop target, when requested.
    let neighbor: UUID?

    var catalog: SurfaceCatalog { f.base.catalog }

    /// `secondTab` adds a later tab while the first stays selected, so a rollback
    /// must restore the pane's selection rather than accept Bonsplit's neighbor.
    init(secondTab: Bool = false, neighborPane: Bool = false) throws {
        f = try CloudWorkspaceRowOpenFixture()
        workspace = try #require(f.base.manager.workspacesById[f.base.originalWorkspaceID])
        workspace.bonsplitController.setContainerFrame(CGRect(x: 0, y: 0, width: 1_000, height: 700))
        pane = try #require(workspace.bonsplitController.allPaneIds.first)
        original = try #require(workspace.focusedPanelId)
        if secondTab {
            _ = try SurfacePaneFactory.makeTerminalPane(
                initialCommand: nil, workingDirectory: nil,
                at: .tab(workspaceID: workspace.id, paneID: pane.id.uuidString, index: nil), focus: false
            )
            workspace.focusPanel(original)
        }
        neighbor = neighborPane ? try SurfacePaneFactory.makeTerminalPane(
            initialCommand: nil, workingDirectory: nil,
            at: .split(workspaceID: workspace.id, paneID: pane.id.uuidString, direction: .right), focus: false
        ).panelID : nil
        panelCount = workspace.panels.count
        layout = Self.shape(workspace.bonsplitController.treeSnapshot())
        focused = workspace.focusedPanelId
    }

    func terminal(_ key: String) -> SurfaceResourceID {
        SurfaceResourceID(machine: f.provider.machine, kind: .terminal, key: key)
    }

    func terminalRow(_ key: String) throws -> CloudTreeNode {
        let rows = CloudTreeNodeBuilder.flattened(CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: catalog.snapshot, localWorkspaces: [], includeLocalMachine: false
        ))
        return try #require(rows.first { $0.dragGroup?.resources == [terminal(key)] })
    }

    /// The real workspace drop action, as a pane or tab-strip drop target calls it.
    func drop(_ row: CloudTreeNode, at spot: CloudSurfaceDropOptimisticTests.Spot) -> Bool {
        guard let group = row.dragGroup else { return false }
        let destination: BonsplitController.ExternalTabDropRequest.Destination = switch spot {
        case .split: .split(targetPane: pane, orientation: .horizontal, insertFirst: false)
        case .tab: .insert(targetPane: pane, targetIndex: nil)
        }
        return workspace.handleSurfaceResourceDrop(group: group, destination: destination, catalog: catalog)
    }

    func expectOriginalLayout(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(workspace.panels.count == panelCount, sourceLocation: sourceLocation)
        #expect(Self.shape(workspace.bonsplitController.treeSnapshot()) == layout, sourceLocation: sourceLocation)
        #expect(workspace.focusedPanelId == focused, sourceLocation: sourceLocation)
    }

    /// Bounded so a missing transition fails here, not at the suite's time limit.
    func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), sourceLocation: sourceLocation)
    }

    /// Panes, their tabs and selected tab in tree order; titles can change on their own.
    static func shape(_ node: ExternalTreeNode) -> [String] {
        switch node {
        case .pane(let pane):
            return ["pane \(pane.id) tabs \(pane.tabs.map(\.id)) selected \(pane.selectedTabId ?? "-")"]
        case .split(let split):
            return ["split \(split.orientation)"] + shape(split.first) + shape(split.second)
        }
    }

    func close() {
        f.close()
    }
}
