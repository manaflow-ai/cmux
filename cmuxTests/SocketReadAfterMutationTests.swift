import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized, .exclusiveAppContext)
struct SocketReadAfterMutationTests {
    @Test("Create, rename and close are visible to the next socket read")
    func workspaceRoundTrip() async throws {
        try await withDeferredRefresh { controller, manager, windowID in
            let scope: [String: Any] = ["window_id": windowID.uuidString]
            let initial = try await call(controller, "workspace.list", scope)
            let initialRows = try #require(initial["workspaces"] as? [[String: Any]])
            let selected = manager.selectedTabId
            var creation = scope
            creation.merge([
                "title": "cli-smoke-regression", "focus": false,
                "eager_load_terminal": false, "auto_refresh_metadata": false
            ]) { _, new in new }
            let receipt = try await call(controller, "workspace.create", creation)
            let workspaceID = try #require(receipt["workspace_id"] as? String)
            let afterCreate = try await rows(controller, windowID)
            #expect(afterCreate.count == initialRows.count + 1)
            #expect(afterCreate.first { $0["id"] as? String == workspaceID }?["title"] as? String == "cli-smoke-regression")
            #expect(manager.selectedTabId == selected)

            _ = try await call(controller, "workspace.rename", [
                "window_id": windowID.uuidString, "workspace_id": workspaceID,
                "title": "renamed-smoke-workspace"
            ])
            let afterRename = try await rows(controller, windowID)
            #expect(afterRename.first { $0["id"] as? String == workspaceID }?["title"] as? String == "renamed-smoke-workspace")

            _ = try await call(controller, "workspace.close", [
                "window_id": windowID.uuidString, "workspace_id": workspaceID
            ])
            let afterClose = try await rows(controller, windowID)
            #expect(!afterClose.contains { $0["id"] as? String == workspaceID })
        }
    }

    @Test("A title notification invalidates scoped reads while a refresh is already queued")
    func notificationDuringPendingRefresh() async throws {
        try await withDeferredRefresh { controller, manager, windowID in
            let workspace = try #require(manager.tabs.first)
            _ = try await rows(controller, windowID)
            #expect(manager.setCustomTitle(tabId: workspace.id, title: "renamed-outside-socket"))
            let listed = try await rows(controller, windowID)
            #expect(listed.first { $0["id"] as? String == workspace.id.uuidString }?["title"] as? String == "renamed-outside-socket")
        }
    }

    private func rows(_ controller: TerminalController, _ windowID: UUID) async throws -> [[String: Any]] {
        let result = try await call(controller, "workspace.list", ["window_id": windowID.uuidString])
        return try #require(result["workspaces"] as? [[String: Any]])
    }

    private func call(_ controller: TerminalController, _ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["id": method, "method": method, "params": params])
        let response = try #require(await controller.processCommandUsingSocketExecutionPolicyAsync(String(decoding: data, as: UTF8.self)))
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        #expect(envelope["id"] as? String == method)
        #expect(envelope["ok"] as? Bool == true)
        return try #require(envelope["result"] as? [String: Any])
    }

    private func withDeferredRefresh(
        _ body: (TerminalController, TabManager, UUID) async throws -> Void
    ) async throws {
        let controller = TerminalController.shared
        let app = try #require(AppDelegate.shared)
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowID = app.registerMainWindowContextForTesting(tabManager: manager)
        await controller.socketReadSnapshotRefreshTask?.value
        // Hold the existing coalescing slot: no sleeps or executor-speed
        // assumptions. Reads must observe mutations before a refresh runs.
        controller.socketReadSnapshotRefreshTask = Task {}
        controller.socketReadSnapshotStore.publish(ControlReadSnapshot())
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            for workspace in manager.tabs { workspace.teardownAllPanels() }
            controller.socketReadSnapshotRefreshTask = nil
            controller.socketReadSnapshotStore.publish(ControlReadSnapshot())
            controller.scheduleSocketReadSnapshotRefresh()
        }
        try await body(controller, manager, windowID)
    }
}
