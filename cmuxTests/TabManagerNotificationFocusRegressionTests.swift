import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct TabManagerNotificationFocusRegressionTests {
    @Test
    func focusTabFromNotificationAcceptsBonsplitSurfaceIdForNestedTabNotification() async throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        _ = workspace.newTerminalSurface(inPane: paneId, focus: false)
        let thirdPanel = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false))
        let thirdSurfaceId = try #require(workspace.surfaceIdFromPanelId(thirdPanel.id)?.uuid)

        workspace.focusPanel(firstPanelId)
        #expect(workspace.focusedPanelId == firstPanelId)
        #expect(manager.focusTabFromNotification(workspace.id, surfaceId: thirdSurfaceId))
        await drainMainQueue()
        await drainMainQueue()

        #expect(workspace.focusedPanelId == thirdPanel.id)
        #expect(workspace.bonsplitController.selectedTab(inPane: paneId)?.id.uuid == thirdSurfaceId)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
