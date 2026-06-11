import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Workspace creation
@MainActor
final class WorkspaceCreationWorkingDirectoryInheritanceTests: XCTestCase {
    @Observable
    fileprivate final class DetachedWorkspaceTestPanel: Panel {
        let id: UUID
        let panelType: PanelType = .terminal
        let displayTitle = "Detached"
        let displayIcon: String? = "terminal.fill"
        let isDirty = false

        init(id: UUID = UUID()) {
            self.id = id
        }

        func close() {}
        func focus() {}
        func unfocus() {}
        func triggerFlash(reason: WorkspaceAttentionFlashReason) {}
    }

    func testNewWorkspaceInheritsSourceWorkingDirectoryByDefault() throws {
        try withWorkspaceWorkingDirectoryInheritanceSetting(nil) {
            let sourceCwd = "/tmp/cmux-source-\(UUID().uuidString)"
            let manager = TabManager(
                initialWorkingDirectory: sourceCwd,
                autoWelcomeIfNeeded: false
            )

            let inserted = manager.addWorkspace(autoWelcomeIfNeeded: false)

            XCTAssertEqual(inserted.focusedTerminalPanel?.requestedWorkingDirectory, sourceCwd)
            XCTAssertEqual(inserted.currentDirectory, sourceCwd)
        }
    }

    func testDisabledInheritanceLeavesNewWorkspaceCwdUnsetForGhosttyConfigFallback() throws {
        try withWorkspaceWorkingDirectoryInheritanceSetting(false) {
            let sourceCwd = "/tmp/cmux-source-\(UUID().uuidString)"
            let manager = TabManager(
                initialWorkingDirectory: sourceCwd,
                autoWelcomeIfNeeded: false
            )

            let inserted = manager.addWorkspace(autoWelcomeIfNeeded: false)

            XCTAssertNil(inserted.focusedTerminalPanel?.requestedWorkingDirectory)
            XCTAssertNotEqual(inserted.currentDirectory, sourceCwd)
        }
    }

    func testExplicitNoInheritanceLeavesNewWorkspaceCwdUnsetWhenGlobalInheritanceEnabled() throws {
        try withWorkspaceWorkingDirectoryInheritanceSetting(nil) {
            let sourceCwd = "/tmp/cmux-source-\(UUID().uuidString)"
            let manager = TabManager(
                initialWorkingDirectory: sourceCwd,
                autoWelcomeIfNeeded: false
            )

            let inserted = manager.addWorkspace(
                inheritWorkingDirectory: false,
                autoWelcomeIfNeeded: false
            )

            XCTAssertNil(inserted.focusedTerminalPanel?.requestedWorkingDirectory)
            XCTAssertNotEqual(inserted.currentDirectory, sourceCwd)
        }
    }

    func testExplicitWorkspaceWorkingDirectoryWinsWhenInheritanceIsDisabled() throws {
        try withWorkspaceWorkingDirectoryInheritanceSetting(false) {
            let sourceCwd = "/tmp/cmux-source-\(UUID().uuidString)"
            let explicitCwd = "/tmp/cmux-explicit-\(UUID().uuidString)"
            let manager = TabManager(
                initialWorkingDirectory: sourceCwd,
                autoWelcomeIfNeeded: false
            )

            let inserted = manager.addWorkspace(
                workingDirectory: explicitCwd,
                autoWelcomeIfNeeded: false
            )

            XCTAssertEqual(inserted.focusedTerminalPanel?.requestedWorkingDirectory, explicitCwd)
            XCTAssertEqual(inserted.currentDirectory, explicitCwd)
        }
    }

    func testDetachedWorkspaceInheritsSourceWorkingDirectoryByDefaultWhenTransferHasNoDirectory() throws {
        try withWorkspaceWorkingDirectoryInheritanceSetting(nil) {
            let sourceCwd = "/tmp/cmux-source-\(UUID().uuidString)"
            let manager = TabManager(
                initialWorkingDirectory: sourceCwd,
                autoWelcomeIfNeeded: false
            )
            let source = try XCTUnwrap(manager.selectedWorkspace)
            let detached = makeDetachedWorkspaceTestTransfer(sourceWorkspaceId: source.id)

            let inserted = try XCTUnwrap(manager.addWorkspace(
                fromDetachedSurface: detached,
                select: false
            ))

            XCTAssertEqual(inserted.currentDirectory, sourceCwd)
            XCTAssertEqual(inserted.surfaceTabBarDirectory, sourceCwd)
        }
    }

    func testDisabledInheritanceLeavesDetachedWorkspaceFallbackCwdUnsetWhenTransferHasNoDirectory() throws {
        try withWorkspaceWorkingDirectoryInheritanceSetting(false) {
            let sourceCwd = "/tmp/cmux-source-\(UUID().uuidString)"
            let fallbackCwd = FileManager.default.homeDirectoryForCurrentUser.path
            let manager = TabManager(
                initialWorkingDirectory: sourceCwd,
                autoWelcomeIfNeeded: false
            )
            let source = try XCTUnwrap(manager.selectedWorkspace)
            let detached = makeDetachedWorkspaceTestTransfer(sourceWorkspaceId: source.id)

            let inserted = try XCTUnwrap(manager.addWorkspace(
                fromDetachedSurface: detached,
                select: false
            ))

            XCTAssertEqual(inserted.currentDirectory, fallbackCwd)
            XCTAssertEqual(inserted.surfaceTabBarDirectory, fallbackCwd)
        }
    }

    func testDetachedWorkspaceTransferDirectoryWinsWhenInheritanceIsDisabled() throws {
        try withWorkspaceWorkingDirectoryInheritanceSetting(false) {
            let sourceCwd = "/tmp/cmux-source-\(UUID().uuidString)"
            let transferCwd = "/tmp/cmux-detached-\(UUID().uuidString)"
            let manager = TabManager(
                initialWorkingDirectory: sourceCwd,
                autoWelcomeIfNeeded: false
            )
            let source = try XCTUnwrap(manager.selectedWorkspace)
            let detached = makeDetachedWorkspaceTestTransfer(
                sourceWorkspaceId: source.id,
                directory: transferCwd
            )

            let inserted = try XCTUnwrap(manager.addWorkspace(
                fromDetachedSurface: detached,
                select: false
            ))

            XCTAssertEqual(inserted.currentDirectory, transferCwd)
            XCTAssertEqual(inserted.surfaceTabBarDirectory, transferCwd)
        }
    }

    func testDetachedWorkspaceDoesNotPersistProcessDetectedResumeBinding() throws {
        let manager = TabManager(
            initialWorkingDirectory: "/tmp/cmux-source-\(UUID().uuidString)",
            autoWelcomeIfNeeded: false
        )
        let source = try XCTUnwrap(manager.selectedWorkspace)
        let binding = SurfaceResumeBindingSnapshot(
            name: "tmux work",
            kind: "tmux",
            command: "tmux attach -t work",
            cwd: "/tmp/cmux-source",
            checkpointId: "work",
            source: "process-detected",
            updatedAt: 1_777_777_777
        )
        let detached = makeDetachedWorkspaceTestTransfer(
            sourceWorkspaceId: source.id,
            resumeBinding: binding
        )

        let inserted = try XCTUnwrap(manager.addWorkspace(
            fromDetachedSurface: detached,
            select: false
        ))

        XCTAssertNil(inserted.surfaceResumeBinding(panelId: detached.panelId))
    }

    private func withWorkspaceWorkingDirectoryInheritanceSetting(
        _ value: Bool?,
        _ body: () throws -> Void
    ) rethrows {
        let defaults = UserDefaults.standard
        let key = WorkspaceWorkingDirectoryInheritanceSettings.key
        let previousValue = defaults.object(forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }

        try body()
    }

    private func makeDetachedWorkspaceTestTransfer(
        sourceWorkspaceId: UUID,
        directory: String? = nil,
        resumeBinding: SurfaceResumeBindingSnapshot? = nil
    ) -> Workspace.DetachedSurfaceTransfer {
        let panel = DetachedWorkspaceTestPanel()
        return Workspace.DetachedSurfaceTransfer(
            sourceWorkspaceId: sourceWorkspaceId,
            panelId: panel.id,
            panel: panel,
            title: panel.displayTitle,
            icon: panel.displayIcon,
            iconImageData: nil,
            kind: "terminal",
            isLoading: false,
            isPinned: false,
            directory: directory,
            ttyName: nil,
            cachedTitle: nil,
            customTitle: nil,
            manuallyUnread: false,
            restoredUnreadIndicator: nil,
            restorableAgent: nil,
            restorableAgentResumeState: nil,
            resumeBinding: resumeBinding,
            agentRuntime: nil,
            isRemoteTerminal: false,
            remoteRelayPort: nil,
            remotePTYSessionID: nil,
            remoteCleanupConfiguration: nil
        )
    }
}


@MainActor
final class WorkspaceCreationPlacementTests: XCTestCase {
    private final class SnapshotMutatingTabManager: TabManager {
        var afterCaptureWorkspaceCreationSnapshot: (() -> Void)?
        var beforeCreateWorkspace: (() -> Void)?

        override func didCaptureWorkspaceCreationSnapshot() {
            afterCaptureWorkspaceCreationSnapshot?()
        }

        override func makeWorkspaceForCreation(
            title: String,
            workingDirectory: String?,
            portOrdinal: Int,
            configTemplate: CmuxSurfaceConfigTemplate?,
            initialTerminalCommand: String?,
            initialTerminalInput: String?,
            initialTerminalEnvironment: [String: String]
        ) -> Workspace {
            beforeCreateWorkspace?()
            return super.makeWorkspaceForCreation(
                title: title,
                workingDirectory: workingDirectory,
                portOrdinal: portOrdinal,
                configTemplate: configTemplate,
                initialTerminalCommand: initialTerminalCommand,
                initialTerminalInput: initialTerminalInput,
                initialTerminalEnvironment: initialTerminalEnvironment
            )
        }
    }

    func testAddWorkspaceDefaultPlacementMatchesCurrentSetting() {
        let currentPlacement = WorkspacePlacementSettings.current()

        let defaultManager = makeManagerWithThreeWorkspaces()
        let defaultBaselineOrder = defaultManager.tabs.map(\.id)
        let defaultInserted = defaultManager.addWorkspace()
        guard let defaultInsertedIndex = defaultManager.tabs.firstIndex(where: { $0.id == defaultInserted.id }) else {
            XCTFail("Expected inserted workspace in tab list")
            return
        }
        XCTAssertEqual(defaultManager.tabs.map(\.id).filter { $0 != defaultInserted.id }, defaultBaselineOrder)

        let explicitManager = makeManagerWithThreeWorkspaces()
        let explicitBaselineOrder = explicitManager.tabs.map(\.id)
        let explicitInserted = explicitManager.addWorkspace(placementOverride: currentPlacement)
        guard let explicitInsertedIndex = explicitManager.tabs.firstIndex(where: { $0.id == explicitInserted.id }) else {
            XCTFail("Expected inserted workspace in tab list")
            return
        }
        XCTAssertEqual(explicitManager.tabs.map(\.id).filter { $0 != explicitInserted.id }, explicitBaselineOrder)
        XCTAssertEqual(defaultInsertedIndex, explicitInsertedIndex)
    }

    func testAddWorkspaceEndOverrideAlwaysAppends() {
        let manager = makeManagerWithThreeWorkspaces()
        let baselineCount = manager.tabs.count
        guard baselineCount >= 3 else {
            XCTFail("Expected at least three workspaces for placement regression test")
            return
        }

        let inserted = manager.addWorkspace(placementOverride: .end)
        guard let insertedIndex = manager.tabs.firstIndex(where: { $0.id == inserted.id }) else {
            XCTFail("Expected inserted workspace in tab list")
            return
        }

        XCTAssertEqual(insertedIndex, baselineCount)
    }

    func testAddWorkspaceInIMessageModeInsertsAtTopOfUnpinnedSegment() {
        let defaults = UserDefaults.standard
        let placementKey = WorkspacePlacementSettings.placementKey
        let iMessageModeKey = IMessageModeSettings.key
        let previousPlacement = defaults.object(forKey: placementKey)
        let previousIMessageMode = defaults.object(forKey: iMessageModeKey)
        defer {
            if let previousPlacement {
                defaults.set(previousPlacement, forKey: placementKey)
            } else {
                defaults.removeObject(forKey: placementKey)
            }
            if let previousIMessageMode {
                defaults.set(previousIMessageMode, forKey: iMessageModeKey)
            } else {
                defaults.removeObject(forKey: iMessageModeKey)
            }
        }

        defaults.set(NewWorkspacePlacement.end.rawValue, forKey: placementKey)
        defaults.set(true, forKey: iMessageModeKey)

        let manager = TabManager()
        guard let pinned = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }
        manager.setPinned(pinned, pinned: true)
        let second = manager.addWorkspace(select: false, placementOverride: .end)
        let third = manager.addWorkspace(select: false, placementOverride: .end)
        manager.selectWorkspace(third)

        let inserted = manager.addWorkspace()

        XCTAssertEqual(manager.tabs.map(\.id), [pinned.id, inserted.id, second.id, third.id])
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testAddWorkspaceAfterCurrentOverrideAppendsAfterLastSelectedWorkspace() {
        let manager = TabManager()
        guard !manager.tabs.isEmpty else {
            XCTFail("Expected TabManager to initialise with at least one workspace")
            return
        }
        _ = manager.addWorkspace()
        _ = manager.addWorkspace()
        let fourth = manager.addWorkspace()
        let baselineOrder = manager.tabs.map(\.id)

        manager.selectWorkspace(fourth)
        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(manager.tabs.map(\.id).filter { $0 != inserted.id }, baselineOrder)
        XCTAssertEqual(manager.tabs.last?.id, inserted.id)
    }

    func testAddWorkspaceAfterCurrentUsesPrecreationSnapshotWhenSelectionMutatesDuringBootstrap() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        manager.setPinned(first, pinned: true)
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(third)

        let baselineOrder = manager.tabs.map(\.id)
        manager.beforeCreateWorkspace = {
            manager.selectWorkspace(first)
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(manager.tabs.map(\.id).filter { $0 != inserted.id }, baselineOrder)
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, second.id, third.id, inserted.id])
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testAddWorkspaceAfterCurrentDoesNotReinsertClosedWorkspaceCapturedInSnapshot() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(third)

        manager.afterCaptureWorkspaceCreationSnapshot = {
            manager.closeWorkspace(second)
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(manager.tabs.map(\.id), [first.id, third.id, inserted.id])
        XCTAssertFalse(manager.tabs.contains(where: { $0.id == second.id }))
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testAddWorkspaceSurvivesSelectedWorkspaceClosingAfterSnapshot() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(third)

        manager.afterCaptureWorkspaceCreationSnapshot = {
            manager.closeWorkspace(third)
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(manager.tabs.map(\.id), [first.id, second.id, inserted.id])
        XCTAssertFalse(manager.tabs.contains(where: { $0.id == third.id }))
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testAddWorkspaceSurvivesMidCreationClose() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        let closingWorkspace = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(third)

        let closingWorkspaceId = closingWorkspace.id
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, closingWorkspaceId, third.id])

        manager.afterCaptureWorkspaceCreationSnapshot = {
            guard let liveWorkspace = manager.tabs.first(where: { $0.id == closingWorkspaceId }) else {
                XCTFail("Expected captured workspace to still be present when closing after snapshot")
                return
            }
            manager.closeWorkspace(liveWorkspace)
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertFalse(manager.tabs.contains(where: { $0.id == closingWorkspaceId }))
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, third.id, inserted.id])
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testAddWorkspaceAfterCurrentUsesSnapshotPinnedStateWhenPinningMutatesAfterSnapshot() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        manager.setPinned(first, pinned: true)
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(first)
        let baselineOrder = manager.tabs.map(\.id)

        manager.afterCaptureWorkspaceCreationSnapshot = {
            manager.setPinned(first, pinned: false)
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(manager.tabs.map(\.id).filter { $0 != inserted.id }, baselineOrder)
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, inserted.id, second.id, third.id])
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testAddWorkspaceAfterCurrentFollowsLiveReorderUsingSnapshotTabValues() {
        let manager = SnapshotMutatingTabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.selectWorkspace(second)

        manager.afterCaptureWorkspaceCreationSnapshot = {
            XCTAssertTrue(
                manager.reorderWorkspace(tabId: third.id, toIndex: 0),
                "Expected to reorder live workspaces after the snapshot is captured"
            )
        }

        let inserted = manager.addWorkspace(placementOverride: .afterCurrent)

        XCTAssertEqual(
            manager.tabs.map(\.id).filter { $0 != inserted.id },
            [third.id, first.id, second.id]
        )
        XCTAssertEqual(manager.tabs.map(\.id), [third.id, first.id, second.id, inserted.id])
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    private func makeManagerWithThreeWorkspaces() -> TabManager {
        let manager = TabManager()
        _ = manager.addWorkspace()
        _ = manager.addWorkspace()
        if let first = manager.tabs.first {
            manager.selectWorkspace(first)
        }
        return manager
    }
}

@MainActor
final class WorkspaceCreationConfigSanitizationTests: XCTestCase {
    private final class UnsafeConfigSnapshotTabManager: TabManager {
        private var injectedConfig: CmuxSurfaceConfigTemplate?
        var capturedConfigTemplate: CmuxSurfaceConfigTemplate?

        func installInjectedConfig(fontSize: Float) {
            var config = CmuxSurfaceConfigTemplate()
            config.fontSize = fontSize
            config.workingDirectory = "/tmp/cmux-workspace-snapshot"
            config.command = "echo snapshot"
            config.environmentVariables = ["CMUX_INHERITED_ENV": "1"]
            injectedConfig = config
        }

        override func inheritedTerminalConfigForNewWorkspace(
            workspace: Workspace?
        ) -> CmuxSurfaceConfigTemplate? {
            injectedConfig ?? super.inheritedTerminalConfigForNewWorkspace(workspace: workspace)
        }

        override func makeWorkspaceForCreation(
            title: String,
            workingDirectory: String?,
            portOrdinal: Int,
            configTemplate: CmuxSurfaceConfigTemplate?,
            initialTerminalCommand: String?,
            initialTerminalInput: String?,
            initialTerminalEnvironment: [String: String]
        ) -> Workspace {
            capturedConfigTemplate = configTemplate
            return super.makeWorkspaceForCreation(
                title: title,
                workingDirectory: workingDirectory,
                portOrdinal: portOrdinal,
                configTemplate: configTemplate,
                initialTerminalCommand: initialTerminalCommand,
                initialTerminalInput: initialTerminalInput,
                initialTerminalEnvironment: initialTerminalEnvironment
            )
        }
    }

    func testAddWorkspacePassesSanitizedInheritedConfigTemplate() {
        let manager = UnsafeConfigSnapshotTabManager()
        manager.installInjectedConfig(fontSize: 19)

        _ = manager.addWorkspace()

        guard let capturedConfig = manager.capturedConfigTemplate else {
            XCTFail("Expected captured config template for new workspace")
            return
        }

        XCTAssertEqual(capturedConfig.fontSize, 19, accuracy: 0.001)
        XCTAssertNil(capturedConfig.workingDirectory)
        XCTAssertNil(capturedConfig.command)
        XCTAssertTrue(capturedConfig.environmentVariables.isEmpty)
    }
}


