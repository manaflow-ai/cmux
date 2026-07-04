import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SystemIdentifyCallerResolutionTests {
    @Test
    func callerSurfaceIDAloneResolvesOwningWorkspace() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        let caller = try identifyCaller(params: [
            "caller": [
                "surface_id": fixture.targetSurfaceID.uuidString,
            ],
        ])

        assertCaller(
            caller,
            windowID: fixture.windowID,
            workspaceID: fixture.targetWorkspace.id,
            surfaceID: fixture.targetSurfaceID,
            paneID: fixture.targetPaneID
        )
    }

    @Test
    func callerSurfaceIDResolvesGloballyWhenWorkspaceIDIsStale() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        let caller = try identifyCaller(params: [
            "caller": [
                "workspace_id": fixture.staleWorkspace.id.uuidString,
                "surface_id": fixture.targetSurfaceID.uuidString,
            ],
        ])

        assertCaller(
            caller,
            windowID: fixture.windowID,
            workspaceID: fixture.targetWorkspace.id,
            surfaceID: fixture.targetSurfaceID,
            paneID: fixture.targetPaneID
        )
    }

    @Test
    func callerWorkspaceIDAloneResolvesWorkspaceWithoutSurface() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        let caller = try identifyCaller(params: [
            "caller": [
                "workspace_id": fixture.targetWorkspace.id.uuidString,
            ],
        ])

        assertWorkspaceOnlyCaller(
            caller,
            windowID: fixture.windowID,
            workspaceID: fixture.targetWorkspace.id
        )
    }

    private struct Fixture {
        let previousAppDelegate: AppDelegate?
        let appDelegate: AppDelegate
        let windowID: UUID
        let manager: TabManager
        let staleWorkspace: Workspace
        let targetWorkspace: Workspace
        let targetSurfaceID: UUID
        let targetPaneID: UUID?

        @MainActor
        func tearDown() {
            TerminalController.shared.setActiveTabManager(nil)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousAppDelegate
        }
    }

    private func makeFixture() throws -> Fixture {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate

        do {
            let manager = TabManager()
            let staleWorkspace = try #require(manager.selectedWorkspace)
            let targetWorkspace = manager.addWorkspace(select: false)
            let targetSurfaceID = try #require(targetWorkspace.focusedPanelId)
            let targetPaneID = targetWorkspace.paneId(forPanelId: targetSurfaceID)?.id
            let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            TerminalController.shared.setActiveTabManager(manager)

            return Fixture(
                previousAppDelegate: previousAppDelegate,
                appDelegate: appDelegate,
                windowID: windowID,
                manager: manager,
                staleWorkspace: staleWorkspace,
                targetWorkspace: targetWorkspace,
                targetSurfaceID: targetSurfaceID,
                targetPaneID: targetPaneID
            )
        } catch {
            // Fixture construction mutates the AppDelegate.shared global before the
            // throwing #require calls run. If one throws, the caller never binds a
            // Fixture, so its `defer { fixture.tearDown() }` never registers — restore
            // the global here so a failed setup can't leak into other serialized tests.
            AppDelegate.shared = previousAppDelegate
            throw error
        }
    }

    private func identifyCaller(params: [String: Any]) throws -> [String: Any] {
        let request: [String: Any] = [
            "id": "identify",
            "method": "system.identify",
            "params": params,
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try #require(String(data: requestData, encoding: .utf8))
        let rawResponse = TerminalController.shared.handleSocketLine(requestLine)
        let responseData = Data(rawResponse.utf8)
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            "Expected JSON-RPC response object, got: \(rawResponse)"
        )
        #expect(envelope["ok"] as? Bool == true)
        let result = try #require(envelope["result"] as? [String: Any])
        return try #require(
            result["caller"] as? [String: Any],
            "Expected system.identify caller, got: \(result["caller"] ?? "nil")"
        )
    }

    private func assertCaller(
        _ caller: [String: Any],
        windowID: UUID,
        workspaceID: UUID,
        surfaceID: UUID,
        paneID: UUID?
    ) {
        #expect(caller["window_id"] as? String == windowID.uuidString)
        #expect(caller["workspace_id"] as? String == workspaceID.uuidString)
        #expect(caller["surface_id"] as? String == surfaceID.uuidString)
        #expect(caller["tab_id"] as? String == surfaceID.uuidString)
        #expect(caller["pane_id"] as? String == paneID?.uuidString)
        #expect(caller["surface_type"] as? String == "terminal")
        #expect(caller["is_browser_surface"] as? Bool == false)
    }

    private func assertWorkspaceOnlyCaller(
        _ caller: [String: Any],
        windowID: UUID,
        workspaceID: UUID
    ) {
        #expect(caller["window_id"] as? String == windowID.uuidString)
        #expect(caller["workspace_id"] as? String == workspaceID.uuidString)
        #expect((caller["surface_id"] as? NSNull) != nil)
        #expect((caller["surface_ref"] as? NSNull) != nil)
        #expect((caller["tab_id"] as? NSNull) != nil)
        #expect((caller["tab_ref"] as? NSNull) != nil)
        #expect((caller["pane_id"] as? NSNull) != nil)
        #expect((caller["pane_ref"] as? NSNull) != nil)
        #expect((caller["surface_type"] as? NSNull) != nil)
        #expect((caller["is_browser_surface"] as? NSNull) != nil)
    }
}
