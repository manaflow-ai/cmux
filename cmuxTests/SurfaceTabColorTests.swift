import CmuxControlSocket
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Surface tab colors", .serialized)
struct SurfaceTabColorTests {
    private func makeTabManager() -> TabManager {
        let suiteName = "cmux.surface-tab-color-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            settings: UserDefaultsSettingsClient(defaults: defaults),
            closeTabWarningDefaults: defaults
        )
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        return manager
    }

    @Test func setAndClearSurfaceColorMutatesTheTab() throws {
        let manager = makeTabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))

        #expect(workspace.bonsplitController.tab(tabId)?.customColor == nil)
        #expect(workspace.setSurfaceColor(panelId: panelId, color: "#1a2b3c"))
        #expect(workspace.bonsplitController.tab(tabId)?.customColor == "#1A2B3C")
        #expect(workspace.setSurfaceColor(panelId: panelId, color: nil))
        #expect(workspace.bonsplitController.tab(tabId)?.customColor == nil)
    }

    @Test func sessionSnapshotRoundTripPreservesSurfaceColor() throws {
        let manager = makeTabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        #expect(workspace.setSurfaceColor(panelId: panelId, color: "#445566"))

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let restoredManager = makeTabManager()
        let restored = try #require(restoredManager.selectedWorkspace)
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restored.focusedPanelId)
        let restoredTabId = try #require(restored.surfaceIdFromPanelId(restoredPanelId))

        #expect(restored.bonsplitController.tab(restoredTabId)?.customColor == "#445566")
    }

    @Test func cliSetAndClearColorUseTheSharedMutationPath() throws {
        let manager = makeTabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panelId))
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: workspace.id,
            surfaceID: panelId,
            paneID: nil
        )

        let setResult = TerminalController.shared.controlTabAction(
            routing: routing,
            actionKey: "set_color",
            title: nil,
            rawURL: nil,
            surfaceID: panelId,
            requestedFocus: false,
            moveParams: ["color": .string("blue")]
        )
        guard case .completed = setResult else {
            Issue.record("Expected set_color to complete, got \(setResult)")
            return
        }
        #expect(workspace.bonsplitController.tab(tabId)?.customColor == "#1565C0")

        let clearResult = TerminalController.shared.controlTabAction(
            routing: routing,
            actionKey: "clear_color",
            title: nil,
            rawURL: nil,
            surfaceID: panelId,
            requestedFocus: false,
            moveParams: [:]
        )
        guard case .completed = clearResult else {
            Issue.record("Expected clear_color to complete, got \(clearResult)")
            return
        }
        #expect(workspace.bonsplitController.tab(tabId)?.customColor == nil)
    }
}
