import CmuxSettings
import CmuxSidebar
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Factory-level coverage for `sidebar.stateIndicatorColors`: exercises
/// `SidebarWorkspaceSnapshotFactory.stateIndicatorOverrideColors()` through
/// the `makeSnapshot()` path against a real `Workspace`'s per-panel agent
/// lifecycle state, so the multi-panel aggregation rules (needsInput >
/// running > idle, manual-key exclusion, unknown never recolors) are pinned
/// where the sidebar rows actually consume them.
@MainActor
@Suite("SidebarWorkspaceSnapshotFactory state indicator overrides")
struct SidebarWorkspaceSnapshotFactoryStateIndicatorTests {
    private static let runningHex = "#FF9500"
    private static let needsInputHex = "#FF3B30"
    private static let idleHex = "#8E8E93"

    @Test
    func overridesAreEmptyWhenNoStateColorsAreConfigured() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .needsInput)

        let snapshot = try makeSnapshot(
            workspace: workspace,
            runningHex: nil,
            needsInputHex: nil,
            idleHex: nil
        )

        #expect(snapshot.metadataEntryOverrideColors.isEmpty)
    }

    @Test
    func singlePanelLifecycleMapsToItsConfiguredStateColor() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .needsInput)

        let snapshot = try makeSnapshot(workspace: workspace)

        #expect(snapshot.metadataEntryOverrideColors == ["claude_code": Self.needsInputHex])
    }

    @Test
    func needsInputDominatesRunningAcrossPanelsForTheSameKey() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let secondPanelId = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false)).id

        workspace.setAgentLifecycle(key: "claude_code", panelId: firstPanelId, lifecycle: .running)
        workspace.setAgentLifecycle(key: "claude_code", panelId: secondPanelId, lifecycle: .needsInput)

        let snapshot = try makeSnapshot(workspace: workspace)

        // A blocked panel must stay visible even while a sibling panel under
        // the same status key is still running.
        #expect(snapshot.metadataEntryOverrideColors == ["claude_code": Self.needsInputHex])
    }

    @Test
    func runningDominatesIdleAcrossPanelsForTheSameKey() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let secondPanelId = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false)).id

        workspace.setAgentLifecycle(key: "codex", panelId: firstPanelId, lifecycle: .idle)
        workspace.setAgentLifecycle(key: "codex", panelId: secondPanelId, lifecycle: .running)

        let snapshot = try makeSnapshot(workspace: workspace)

        #expect(snapshot.metadataEntryOverrideColors == ["codex": Self.runningHex])
    }

    @Test
    func manualLoaderKeysNeverContributeOverrides() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        // `cmux workspace loading` loaders are recorded as always-running
        // manual lifecycles; they drive the spinner, never a status pill.
        workspace.setAgentLifecycle(key: "manual", panelId: panelId, lifecycle: .running)
        workspace.setAgentLifecycle(key: "manual:loader-1", panelId: panelId, lifecycle: .running)
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .idle)

        let snapshot = try makeSnapshot(workspace: workspace)

        #expect(snapshot.metadataEntryOverrideColors == ["codex": Self.idleHex])
    }

    @Test
    func unknownLifecyclesAndKeysWithoutLifecyclesGetNoOverride() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)

        workspace.setAgentLifecycle(key: "gemini", panelId: panelId, lifecycle: .unknown)
        // A status entry whose key has no recorded lifecycle keeps the
        // producer-reported color: it must not appear in the override map.
        workspace.statusEntries["custom_note"] = SidebarStatusEntry(
            key: "custom_note",
            value: "hello",
            color: "#4C8DFF"
        )

        let snapshot = try makeSnapshot(workspace: workspace)

        #expect(snapshot.metadataEntryOverrideColors.isEmpty)
    }

    /// Builds a factory snapshot for `workspace` with the given
    /// `sidebar.stateIndicatorColors` values seeded into a scoped defaults
    /// suite (`nil` leaves a state unconfigured).
    private func makeSnapshot(
        workspace: Workspace,
        runningHex: String? = SidebarWorkspaceSnapshotFactoryStateIndicatorTests.runningHex,
        needsInputHex: String? = SidebarWorkspaceSnapshotFactoryStateIndicatorTests.needsInputHex,
        idleHex: String? = SidebarWorkspaceSnapshotFactoryStateIndicatorTests.idleHex
    ) throws -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        let suiteName = "SidebarWorkspaceSnapshotFactoryStateIndicatorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sidebar = SidebarCatalogSection()
        if let runningHex {
            defaults.set(runningHex, forKey: sidebar.stateIndicatorRunningColorHex.userDefaultsKey)
        }
        if let needsInputHex {
            defaults.set(needsInputHex, forKey: sidebar.stateIndicatorNeedsInputColorHex.userDefaultsKey)
        }
        if let idleHex {
            defaults.set(idleHex, forKey: sidebar.stateIndicatorIdleColorHex.userDefaultsKey)
        }

        let factory = SidebarWorkspaceSnapshotFactory(
            workspace: workspace,
            settings: SidebarTabItemSettingsSnapshot(defaults: defaults),
            showsAgentActivity: true
        )
        return factory.makeSnapshot()
    }
}
