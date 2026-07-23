import Foundation
import Testing
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Workspace explicit detached sources", .serialized)
struct WorkspaceExplicitDetachedSourceTests {
    @Test
    func detachedWorkspaceUsesExplicitUnselectedSourceForInheritance() throws {
        try withWorkspaceWorkingDirectoryInheritanceSetting(nil) {
            let selectedCwd = "/tmp/cmux-selected-\(UUID().uuidString)"
            let targetCwd = "/tmp/cmux-target-\(UUID().uuidString)"
            let manager = TabManager(
                initialWorkingDirectory: selectedCwd,
                autoWelcomeIfNeeded: false
            )
            let selectedWorkspace = try #require(manager.selectedWorkspace)
            let targetWorkspace = manager.addWorkspace(
                workingDirectory: targetCwd,
                inheritWorkingDirectory: false,
                select: false,
                autoWelcomeIfNeeded: false
            )
            let detached = makeDetachedWorkspaceTestTransfer(
                sourceWorkspaceID: targetWorkspace.id
            )

            let inserted = try #require(manager.addWorkspace(
                fromDetachedSurface: detached,
                select: false,
                sourceWorkspaceID: targetWorkspace.id
            ))

            #expect(inserted.currentDirectory == targetCwd)
            #expect(inserted.surfaceTabBarDirectory == targetCwd)
            #expect(manager.selectedWorkspace?.id == selectedWorkspace.id)
        }
    }

    @Test
    func detachedWorkspaceRejectsStaleExplicitSource() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let source = try #require(manager.selectedWorkspace)
        let detached = makeDetachedWorkspaceTestTransfer(sourceWorkspaceID: source.id)
        let originalWorkspaceIDs = manager.tabs.map(\.id)

        #expect(manager.addWorkspace(
            fromDetachedSurface: detached,
            select: false,
            sourceWorkspaceID: UUID()
        ) == nil)
        #expect(manager.tabs.map(\.id) == originalWorkspaceIDs)
    }

    private func withWorkspaceWorkingDirectoryInheritanceSetting(
        _ value: Bool?,
        _ body: () throws -> Void
    ) rethrows {
        let defaults = UserDefaults.standard
        let key = SettingCatalog().app.workspaceInheritWorkingDirectory.userDefaultsKey
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
        sourceWorkspaceID: UUID
    ) -> Workspace.DetachedSurfaceTransfer {
        let panel = WorkspaceExplicitDetachedSourceTestPanel()
        return Workspace.DetachedSurfaceTransfer(
            sourceWorkspaceId: sourceWorkspaceID,
            panelId: panel.id,
            panel: panel,
            title: panel.displayTitle,
            icon: panel.displayIcon,
            iconImageData: nil,
            kind: "terminal",
            isLoading: false,
            isPinned: false,
            directory: nil,
            directoryIsTrustedRemoteReport: false,
            directoryDisplayLabel: nil,
            ttyName: nil,
            cachedTitle: nil,
            customTitle: nil,
            customTitleSource: nil,
            manuallyUnread: false,
            restoredUnreadIndicator: nil,
            restorableAgent: nil,
            restorableAgentResumeState: nil,
            restoredAgentCompletedGeneration: nil,
            shellActivityState: nil,
            restoredResumeSessionWorkingDirectory: nil,
            resumeBinding: nil,
            agentRuntime: nil,
            isRemoteTerminal: false,
            remoteRelayPort: nil,
            remotePTYSessionID: nil,
            remoteCleanupConfiguration: nil
        )
    }
}
