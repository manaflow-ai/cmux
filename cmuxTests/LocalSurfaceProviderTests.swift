import Bonsplit
import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// This Mac's panes as surface resources: one resource per terminal/browser pane, exactly
/// one projection, moving with the pane and ending when the pane closes.
@MainActor
final class LocalSurfaceProviderTests: XCTestCase {
    func testMoveTargetMapsDestinationsOntoBonsplit() {
        let focused = PaneID()
        let pane = PaneID()
        let ws = UUID()
        XCTAssertEqual(
            LocalSurfaceProvider.moveTarget(for: .workspace(id: ws, placement: .split), focusedPane: focused),
            LocalSurfaceProvider.MoveTarget(pane: focused, index: nil, split: (.horizontal, false))
        )
        XCTAssertEqual(
            LocalSurfaceProvider.moveTarget(for: .workspace(id: ws, placement: .tab), focusedPane: focused),
            LocalSurfaceProvider.MoveTarget(pane: focused, index: nil, split: nil)
        )
        XCTAssertEqual(
            LocalSurfaceProvider.moveTarget(for: .split(workspaceID: ws, paneID: pane.id.uuidString, direction: .left), focusedPane: focused),
            LocalSurfaceProvider.MoveTarget(pane: pane, index: nil, split: (.horizontal, true))
        )
        XCTAssertEqual(
            LocalSurfaceProvider.moveTarget(for: .split(workspaceID: ws, paneID: pane.id.uuidString, direction: .down), focusedPane: focused),
            LocalSurfaceProvider.MoveTarget(pane: pane, index: nil, split: (.vertical, false))
        )
        XCTAssertEqual(
            LocalSurfaceProvider.moveTarget(for: .tab(workspaceID: ws, paneID: pane.id.uuidString, index: 2), focusedPane: focused),
            LocalSurfaceProvider.MoveTarget(pane: pane, index: 2, split: nil)
        )
        XCTAssertNil(LocalSurfaceProvider.moveTarget(for: .tab(workspaceID: ws, paneID: "not-a-uuid", index: nil), focusedPane: focused).pane)
    }

    func testShellQuoteLeavesPlainWordsAndQuotesTheRest() {
        XCTAssertEqual(LocalSurfaceProvider.shellQuote("cargo"), "cargo")
        XCTAssertEqual(LocalSurfaceProvider.shellQuote("/root/app"), "/root/app")
        XCTAssertEqual(LocalSurfaceProvider.shellQuote("hello world"), "'hello world'")
        XCTAssertEqual(LocalSurfaceProvider.shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(LocalSurfaceProvider.shellQuote(""), "''")
    }

    func testTerminalPaneIsALocalResourceWithOneProjectionUntilItCloses() throws {
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true)
        let terminals = workspace.panels.filter { $0.value is TerminalPanel }
        let panelID = try XCTUnwrap(terminals.keys.first, "a new workspace opens with a terminal pane")
        let catalog = SurfaceCatalog.shared

        let projection = try XCTUnwrap(catalog.projection(forPanel: panelID))
        XCTAssertEqual(projection.resource, LocalSurfaceProvider.resourceID(forTerminalPanel: panelID))
        XCTAssertEqual(projection.workspaceID, workspace.id)
        XCTAssertEqual(catalog.projections(of: projection.resource).count, 1)
        let resource = try XCTUnwrap(catalog.resources[projection.resource])
        XCTAssertEqual(resource.kind, .terminal)
        XCTAssertTrue(resource.machine.isLocal)

        // The tab bar title is the resource title.
        workspace.panelTitles[panelID] = "cargo test"
        XCTAssertEqual(catalog.resources[projection.resource]?.title, "cargo test")

        XCTAssertTrue(workspace.closePanel(panelID, force: true))
        XCTAssertNil(catalog.projection(forPanel: panelID))
        XCTAssertNil(catalog.resources[projection.resource], "closing the pane drops the local resource")
        manager.closeWorkspace(workspace, recordHistory: false)
    }

    func testTransferringAPaneBetweenWorkspacesMovesItsProjection() throws {
        let manager = TabManager()
        let source = manager.addWorkspace(select: true)
        let target = manager.addWorkspace(select: true)
        let panelID = try XCTUnwrap(source.panels.first { $0.value is TerminalPanel }?.key)
        let catalog = SurfaceCatalog.shared
        let resourceID = LocalSurfaceProvider.resourceID(forTerminalPanel: panelID)
        XCTAssertEqual(catalog.projection(forPanel: panelID)?.workspaceID, source.id)

        let detached = try XCTUnwrap(source.detachSurface(panelId: panelID))
        XCTAssertNotNil(catalog.resources[resourceID], "a pane in flight keeps its resource")
        let targetPane = try XCTUnwrap(target.bonsplitController.allPaneIds.first)
        XCTAssertNotNil(target.attachDetachedSurface(detached, inPane: targetPane))

        XCTAssertEqual(catalog.projection(forPanel: panelID)?.workspaceID, target.id)
        XCTAssertEqual(catalog.projections(of: resourceID).count, 1)
        manager.closeWorkspace(source, recordHistory: false)
        manager.closeWorkspace(target, recordHistory: false)
    }

    func testARemoteProjectionSupersedesTheLocalPlaceholderForTheSamePane() {
        let catalog = SurfaceCatalog()
        let panelID = UUID(), workspaceID = UUID()
        let local = SurfaceResource(id: LocalSurfaceProvider.resourceID(forTerminalPanel: panelID), title: "zsh", detail: nil, lifecycle: .running, agent: nil, remoteWorkspace: nil, port: nil, url: nil)
        catalog.upsert(local)
        catalog.record(SurfaceProjection(resource: local.id, workspaceID: workspaceID, panelID: panelID))

        let remoteID = SurfaceResourceID(machine: .cloud("vivid-newt"), kind: .terminal, key: "term_1")
        catalog.upsert(SurfaceResource(id: remoteID, title: "root@vivid-newt", detail: "/root", lifecycle: .running, agent: nil, remoteWorkspace: nil, port: nil, url: nil))
        catalog.record(SurfaceProjection(resource: remoteID, workspaceID: workspaceID, panelID: panelID))

        XCTAssertEqual(catalog.projection(forPanel: panelID)?.resource, remoteID)
        XCTAssertNil(catalog.resources[local.id], "the pane counts once, as the remote terminal")
        XCTAssertEqual(catalog.snapshot.projections.count, 1)
    }
}
