import AppKit
import CmuxSettings
import CmuxSettingsUI
import CmuxWorkspaces
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SidebarWorkspaceTodoFlagRefreshTests {
    @Test(arguments: [false, true])
    func gateFlipsRefreshCachedDoneRow(localOptIn: Bool) async throws {
        let suite = "SidebarWorkspaceTodoFlagRefreshTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let store = UserDefaultsSettingsStore(defaults: defaults)
        let catalog = SettingCatalog()
        let runtime = SettingsRuntime(
            catalog: catalog,
            userDefaultsStore: store,
            jsonStore: JSONConfigStore(fileURL: directory.appendingPathComponent("cmux.json")),
            secretStore: SecretFileStore(baseDirectory: directory),
            errorLog: SettingsErrorLog()
        )
        // Reuse the flag registry's definition rather than changing the
        // process-wide PostHog singleton or persisted application defaults.
        let todoFlag = try #require(CmuxFeatureFlags.allFlags.first {
            $0.key.contains("workspace-todo-controls")
        })
        var remoteEnabled = false
        let flags = CmuxFeatureFlags(defaults: defaults, remoteFlagValueProvider: { key in
            if key == CmuxFeatureFlags.appKitSidebarListFlag.key { return true }
            if key == todoFlag.key { return remoteEnabled }
            return nil
        })
        flags.applyLoadedFlags()
        let harness = try await SidebarLazyLayoutScaleTests.mountSidebar(
            workspaceCount: 2,
            includeGroups: false,
            featureFlags: flags,
            settingsRuntime: runtime
        )
        defer {
            harness.tearDown()
            harness.tabManager.tabs.forEach { $0.teardownAllPanels() }
        }
        let workspace = try #require(harness.tabManager.tabs.first)
        workspace.setTaskStatusOverride(.done)
        try await waitForRow(harness, workspaceID: workspace.id, enabled: false)

        // After seeding the row, change only the gate: no rename, selection,
        // workspace mutation, or forced snapshot refresh may unstick it.
        for enabled in [true, false, true] {
            if localOptIn {
                await store.set(enabled, for: catalog.betaFeatures.workspaceTodoControls)
            } else {
                remoteEnabled = enabled
                flags.applyLoadedFlags()
            }
            try await waitForRow(harness, workspaceID: workspace.id, enabled: enabled)
            #expect(workspace.todoState.statusOverride?.status == .done)
        }
    }

    private func waitForRow(
        _ harness: SidebarLazyLayoutScaleTests.Harness,
        workspaceID: UUID,
        enabled: Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        var lastModel: SidebarWorkspaceRowModel?
        repeat {
            SidebarLazyLayoutScaleTests.turnMainRunLoopOnce(layingOut: harness.window)
            await Task.yield()
            if let content = harness.window.contentView {
                lastModel = SidebarAppKitRowCellTests.descendants(of: content)
                    .compactMap { ($0 as? SidebarWorkspaceRowTableCellView)?.currentModelForMeasurement }
                    .first { $0.workspaceId == workspaceID }
            }
            if let model = lastModel,
               model.snapshot.taskStatusInput.activeOverride == .done,
               model.todoControlsEnabled == enabled,
               model.snapshot.taskStatus == (enabled ? .done : nil),
               model.snapshot.hasManualTaskStatus == enabled,
               (model.snapshot.todoStatusMenuModel != nil) == enabled {
                return
            }
        } while .now < deadline
        let model = try #require(lastModel, "The real sidebar must materialize the fixture row.")
        #expect(model.snapshot.taskStatusInput.activeOverride == .done)
        #expect(model.todoControlsEnabled == enabled)
        #expect(model.snapshot.taskStatus == (enabled ? .done : nil))
        #expect(model.snapshot.hasManualTaskStatus == enabled)
        #expect((model.snapshot.todoStatusMenuModel != nil) == enabled)
    }
}
