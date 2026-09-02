import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Cmd+T / Cmd+D in a pane that projects a cloud terminal create the machine's new
/// terminal through ``SurfacePaneFactory`` (`Workspace+CloudPaneRouting`). The factory
/// drives the socket `surface.create` / `surface.split` handlers, which honor a focus
/// request only inside a focus-allowed socket command. An in-app gesture runs with no
/// socket command active, so without the factory setting that policy itself the new tab
/// appears behind the current one and Cmd+T looks like it did nothing.
@MainActor
@Suite(.serialized) struct SurfacePaneFactoryFocusTests {
    @Test func focusedTabIsSelectedOutsideASocketCommand() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let before = try #require(workspace.focusedPanelId)
        #expect(TerminalController.currentSocketCommandFocusAllowanceStack().isEmpty)

        let created = try SurfacePaneFactory.makeTerminalPane(
            initialCommand: nil,
            workingDirectory: nil,
            at: .tab(workspaceID: workspace.id, paneID: paneID.id.uuidString, index: nil),
            focus: true
        )

        #expect(created.workspaceID == workspace.id)
        #expect(created.panelID != before)
        #expect(workspace.focusedPanelId == created.panelID)
        let selectedSurface = try #require(workspace.bonsplitController.selectedTab(inPane: paneID)?.id)
        #expect(workspace.panelIdFromSurfaceId(selectedSurface) == created.panelID)
    }

    @Test func unfocusedTabStaysBehindTheCurrentOne() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let before = try #require(workspace.focusedPanelId)

        let created = try SurfacePaneFactory.makeTerminalPane(
            initialCommand: nil,
            workingDirectory: nil,
            at: .tab(workspaceID: workspace.id, paneID: paneID.id.uuidString, index: nil),
            focus: false
        )

        #expect(created.panelID != before)
        #expect(workspace.focusedPanelId == before)
        let selectedSurface = try #require(workspace.bonsplitController.selectedTab(inPane: paneID)?.id)
        #expect(workspace.panelIdFromSurfaceId(selectedSurface) == before)
    }

    /// Cmd+D from a cloud pane (`routeCloudPaneTerminalSplit`) lands in the split
    /// handler with the same gate; the new pane must take focus when asked.
    @Test func focusedSplitFocusesTheNewPane() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let before = try #require(workspace.focusedPanelId)

        let created = try SurfacePaneFactory.makeTerminalPane(
            initialCommand: nil,
            workingDirectory: nil,
            at: .split(workspaceID: workspace.id, paneID: paneID.id.uuidString, direction: .right),
            focus: true
        )

        #expect(created.panelID != before)
        #expect(workspace.focusedPanelId == created.panelID)
        #expect(workspace.paneId(forPanelId: created.panelID) != paneID)
    }

    /// A projected browser (VM desktop or port preview) goes through the same create
    /// handler as a terminal; `focus: true` must select it too.
    @Test func focusedBrowserTabIsSelected() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let before = try #require(workspace.focusedPanelId)

        let created = try SurfacePaneFactory.makeBrowserPane(
            url: SurfacePaneFactory.blankURL,
            at: .tab(workspaceID: workspace.id, paneID: paneID.id.uuidString, index: nil),
            focus: true
        )

        #expect(created.panelID != before)
        #expect(workspace.focusedPanelId == created.panelID)
        let selectedSurface = try #require(workspace.bonsplitController.selectedTab(inPane: paneID)?.id)
        #expect(workspace.panelIdFromSurfaceId(selectedSurface) == created.panelID)
    }

    /// Inside a socket command whose policy forbids focus mutations, the factory must
    /// not re-enable them: the outer policy wins over the caller's `focus: true`.
    @Test func focusRequestCannotEscapeAFocusForbiddingSocketPolicy() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let workspace = harness.workspace
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let before = try #require(workspace.focusedPanelId)

        let created = try TerminalController.withSocketCommandPolicyStack([false]) {
            try SurfacePaneFactory.makeTerminalPane(
                initialCommand: nil,
                workingDirectory: nil,
                at: .tab(workspaceID: workspace.id, paneID: paneID.id.uuidString, index: nil),
                focus: true
            )
        }

        #expect(created.panelID != before)
        #expect(workspace.focusedPanelId == before)
        let selectedSurface = try #require(workspace.bonsplitController.selectedTab(inPane: paneID)?.id)
        #expect(workspace.panelIdFromSurfaceId(selectedSurface) == before)
    }

    @MainActor
    private struct Harness {
        let appDelegate: AppDelegate
        let windowId: UUID
        let workspace: Workspace

        init() throws {
            appDelegate = try #require(AppDelegate.shared)
            windowId = appDelegate.createMainWindow()
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            workspace = try #require(manager.selectedWorkspace)
        }

        func tearDown() {
            let identifier = "cmux.main.\(windowId.uuidString)"
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier }) {
                window.performClose(nil)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }
    }
}
