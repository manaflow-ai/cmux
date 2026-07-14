import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Command deep-link execution planning", .serialized)
struct CmuxRunURLCoordinatorTests {
    @Test func workspacePlanFreezesTheReceivingWindow() throws {
        let app = AppDelegate()
        let manager = TabManager()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager, window: window)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.close()
        }

        let request = try workspaceRequest()
        let result = CmuxRunURLCoordinator(appDelegate: app).makePlan(
            request: request,
            workingDirectory: "/tmp"
        )

        guard case .success(let plan) = result else {
            Issue.record("Expected a workspace plan, saw \(result)")
            return
        }
        #expect(
            plan.target == .workspace(
                windowId: windowId,
                tabManagerIdentity: ObjectIdentifier(manager)
            )
        )
        #expect(plan.command == "true")
        #expect(plan.workingDirectory == "/tmp")
    }

    @Test func stableSurfaceAnchorResolvesToCurrentPane() throws {
        let app = AppDelegate()
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId])
        let paneId = try #require(workspace.paneId(forPanelId: panelId)).id
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager, window: window)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.close()
        }
        let request = try targetRequest(
            placement: .surface,
            workspaceId: workspace.stableId,
            anchor: .surface(panel.stableSurfaceId),
            direction: nil
        )

        let result = CmuxRunURLCoordinator(appDelegate: app).makePlan(
            request: request,
            workingDirectory: "/tmp"
        )

        guard case .success(let plan) = result else {
            Issue.record("Expected a surface plan, saw \(result)")
            return
        }
        #expect(
            plan.target == .surface(
                windowId: windowId,
                workspaceId: workspace.id,
                paneId: paneId,
                anchorPanelId: panelId
            )
        )
    }

    @Test func remoteTmuxWorkspaceIsRejectedBeforeApproval() throws {
        let app = AppDelegate()
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId])
        workspace.isRemoteTmuxMirror = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager, window: window)
        defer {
            workspace.isRemoteTmuxMirror = false
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.close()
        }
        let request = try targetRequest(
            placement: .surface,
            workspaceId: workspace.stableId,
            anchor: .surface(panel.stableSurfaceId),
            direction: nil
        )

        #expect(
            CmuxRunURLCoordinator(appDelegate: app).makePlan(
                request: request,
                workingDirectory: "/tmp"
            ) == .failure(.remoteWorkspaceUnsupported)
        )
    }

    @Test func approvedWorkspacePlanCreatesExactlyOneWorkspace() throws {
        let app = AppDelegate()
        let manager = TabManager()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager, window: window)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.close()
        }
        let initialCount = manager.tabs.count
        let plan = CmuxRunExecutionPlan(
            command: "true",
            workingDirectory: "/tmp",
            target: .workspace(
                windowId: windowId,
                tabManagerIdentity: ObjectIdentifier(manager)
            ),
            placementDescription: "New workspace",
            targetDescription: "Test window"
        )

        switch CmuxRunURLCoordinator(appDelegate: app).execute(plan) {
        case .success:
            break
        case .failure(let error):
            Issue.record("Expected workspace creation to succeed, saw \(error)")
        }
        #expect(manager.tabs.count == initialCount + 1)
    }

    @Test func approvedSurfacePlanCreatesAndFocusesTabInBackgroundWorkspace() throws {
        let app = AppDelegate()
        let manager = TabManager()
        let targetWorkspace = manager.addWorkspace(select: false)
        let sourcePanelId = try #require(targetWorkspace.focusedPanelId)
        let paneId = try #require(targetWorkspace.paneId(forPanelId: sourcePanelId)).id
        let initialPanelCount = targetWorkspace.panels.count
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager, window: window)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.close()
        }
        let plan = CmuxRunExecutionPlan(
            command: "true",
            workingDirectory: "/tmp",
            target: .surface(
                windowId: windowId,
                workspaceId: targetWorkspace.id,
                paneId: paneId,
                anchorPanelId: sourcePanelId
            ),
            placementDescription: "New tab",
            targetDescription: "Background workspace"
        )

        switch CmuxRunURLCoordinator(appDelegate: app).execute(plan) {
        case .success:
            break
        case .failure(let error):
            Issue.record("Expected tab creation to succeed, saw \(error)")
        }
        let newPanelId = try #require(targetWorkspace.focusedPanelId)
        #expect(targetWorkspace.panels.count == initialPanelCount + 1)
        #expect(newPanelId != sourcePanelId)
        #expect(targetWorkspace.paneId(forPanelId: newPanelId)?.id == paneId)
        #expect(manager.selectedTabId == targetWorkspace.id)
    }

    @Test func approvedPanePlanCreatesAndFocusesSplitInBackgroundWorkspace() throws {
        let app = AppDelegate()
        let manager = TabManager()
        let targetWorkspace = manager.addWorkspace(select: false)
        let sourcePanelId = try #require(targetWorkspace.focusedPanelId)
        let sourcePaneId = try #require(targetWorkspace.paneId(forPanelId: sourcePanelId)).id
        let initialPaneCount = targetWorkspace.bonsplitController.allPaneIds.count
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager, window: window)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.close()
        }
        let plan = CmuxRunExecutionPlan(
            command: "true",
            workingDirectory: "/tmp",
            target: .pane(
                windowId: windowId,
                workspaceId: targetWorkspace.id,
                paneId: sourcePaneId,
                sourcePanelId: sourcePanelId,
                direction: .right
            ),
            placementDescription: "New split",
            targetDescription: "Background workspace"
        )

        switch CmuxRunURLCoordinator(appDelegate: app).execute(plan) {
        case .success:
            break
        case .failure(let error):
            Issue.record("Expected split creation to succeed, saw \(error)")
        }
        let newPanelId = try #require(targetWorkspace.focusedPanelId)
        #expect(targetWorkspace.bonsplitController.allPaneIds.count == initialPaneCount + 1)
        #expect(newPanelId != sourcePanelId)
        #expect(targetWorkspace.paneId(forPanelId: newPanelId)?.id != sourcePaneId)
        #expect(manager.selectedTabId == targetWorkspace.id)
    }

    private func workspaceRequest() throws -> CmuxRunURLRequest {
        CmuxRunURLRequest(
            originalURL: try #require(URL(string: "cmux://run")),
            command: "true",
            workingDirectory: "/tmp",
            placement: .workspace,
            workspaceId: nil,
            anchor: nil,
            direction: nil
        )
    }

    private func targetRequest(
        placement: CmuxRunURLRequest.Placement,
        workspaceId: UUID,
        anchor: CmuxRunURLRequest.Anchor,
        direction: CmuxRunURLRequest.Direction?
    ) throws -> CmuxRunURLRequest {
        CmuxRunURLRequest(
            originalURL: try #require(URL(string: "cmux://run")),
            command: "true",
            workingDirectory: "/tmp",
            placement: placement,
            workspaceId: workspaceId,
            anchor: anchor,
            direction: direction
        )
    }
}
