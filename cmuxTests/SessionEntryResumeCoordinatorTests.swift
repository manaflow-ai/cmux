import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SessionEntryResumeCoordinatorTests {
    @Test("Vault resume always creates a new workspace")
    func coordinatorResumesInNewWorkspace() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let matchingDirectory = "/tmp/vault-coordinator-match"
        let manager = TabManager(
            initialWorkingDirectory: matchingDirectory,
            autoWelcomeIfNeeded: false
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let originalWorkspace = try #require(manager.selectedWorkspace)

        let matchingEntry = SessionEntry(
            id: "codex:matching-session",
            agent: .codex,
            sessionId: "01a06e0d-8793-7f33-b044-2b49a10c2261",
            title: "Matching session",
            cwd: matchingDirectory,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_005),
            fileURL: nil, indexedCodexHome: home.path,
            specifics: .codex(
                model: nil,
                approvalPolicy: nil,
                sandboxMode: nil,
                effort: nil
            )
        )
        let matchingLaunch = try #require(matchingEntry.resumeLaunch)

        await SessionEntryResumeCoordinator(tabManager: manager).resume(matchingEntry)

        #expect(manager.tabs.count == 2)
        let matchingWorkspace = try #require(manager.selectedWorkspace)
        #expect(matchingWorkspace !== originalWorkspace)
        #expect(matchingWorkspace.currentDirectory == matchingDirectory)
        let matchingPanelID = try #require(matchingWorkspace.focusedPanelId)
        #expect(
            matchingWorkspace.restoredAgentSnapshotsByPanelId[matchingPanelID]?.sessionId
                == "01a06e0d-8793-7f33-b044-2b49a10c2261"
        )
        #expect(
            matchingWorkspace.restoredResumeSessionWorkingDirectoriesByPanelId[matchingPanelID]
                == matchingDirectory
        )
        #expect(
            matchingWorkspace.terminalPanel(for: matchingPanelID)?
                .surface.debugInitialInputForTesting() == matchingLaunch.initialInput
        )

        let differentDirectory = "/tmp/vault-coordinator-new-workspace"
        let differentEntry = SessionEntry(
            id: "codex:different-session",
            agent: .codex,
            sessionId: "01a06e0d-8793-7f33-b044-2b49a10c2262",
            title: "Different session",
            cwd: differentDirectory,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_006),
            fileURL: nil, indexedCodexHome: home.path,
            specifics: .codex(
                model: nil,
                approvalPolicy: nil,
                sandboxMode: nil,
                effort: nil
            )
        )
        let differentLaunch = try #require(differentEntry.resumeLaunch)

        await SessionEntryResumeCoordinator(tabManager: manager).resume(differentEntry)

        #expect(manager.tabs.count == 3)
        let createdWorkspace = try #require(manager.selectedWorkspace)
        #expect(createdWorkspace !== originalWorkspace)
        #expect(createdWorkspace !== matchingWorkspace)
        #expect(createdWorkspace.currentDirectory == differentDirectory)
        let createdPanelID = try #require(createdWorkspace.focusedPanelId)
        #expect(
            createdWorkspace.restoredAgentSnapshotsByPanelId[createdPanelID]?.sessionId
                == "01a06e0d-8793-7f33-b044-2b49a10c2262"
        )
        #expect(
            createdWorkspace.restoredResumeSessionWorkingDirectoriesByPanelId[createdPanelID]
                == differentDirectory
        )
        #expect(
            createdWorkspace.terminalPanel(for: createdPanelID)?
            .surface.debugInitialInputForTesting() == differentLaunch.initialInput
        )
    }

    @Test("Open Session ignores stale Codex snapshots when the lock is available")
    func coordinatorOpensActiveSessionInCurrentWorkspaceSplit() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let workingDirectory = "/tmp/vault-coordinator-open"
        let manager = TabManager(
            initialWorkingDirectory: workingDirectory,
            autoWelcomeIfNeeded: false
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.selectedWorkspace)
        let initialPaneID = try #require(workspace.bonsplitController.focusedPaneId)

        let entry = SessionEntry(
            id: "codex:already-active-session",
            agent: .codex,
            sessionId: "01a06e0d-8793-7f33-b044-2b49a10c2263",
            title: "Already active",
            cwd: workingDirectory,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_007),
            fileURL: nil, indexedCodexHome: home.path,
            specifics: .codex(
                model: nil,
                approvalPolicy: nil,
                sandboxMode: nil,
                effort: nil
            )
        )
        let launch = try #require(entry.resumeLaunch)
        let snapshot = try #require(launch.startupRestoreAgent)

        let existingPanel = try #require(workspace.newTerminalSurface(
            inPane: initialPaneID,
            focus: true,
            workingDirectory: launch.workingDirectory,
            initialInput: launch.initialInput,
            startupRestoreAgent: snapshot
        ))
        #expect(
            workspace.restoredAgentSnapshotsByPanelId[existingPanel.id]?.sessionId
                == entry.sessionId
        )
        let paneCountBefore = workspace.bonsplitController.allPaneIds.count
        let panelCountBefore = workspace.panels.count

        await SessionEntryResumeCoordinator(tabManager: manager).open(entry)

        #expect(manager.tabs.count == 1)
        #expect(manager.selectedWorkspace === workspace)
        #expect(workspace.bonsplitController.allPaneIds.count == paneCountBefore + 1)
        #expect(workspace.panels.count == panelCountBefore + 1)
        let openedPanelID = try #require(workspace.focusedPanelId)
        #expect(openedPanelID != existingPanel.id)
        #expect(
            workspace.restoredAgentSnapshotsByPanelId[openedPanelID]?.sessionId
                == entry.sessionId
        )
        #expect(
            workspace.restoredResumeSessionWorkingDirectoriesByPanelId[openedPanelID]
                == workingDirectory
        )
        #expect(
            workspace.terminalPanel(for: openedPanelID)?
                .surface.debugInitialInputForTesting() == launch.initialInput
        )
    }
}
