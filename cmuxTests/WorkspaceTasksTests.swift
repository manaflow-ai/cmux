import CmuxSettings
import CoreGraphics
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct WorkspaceTasksTests {
    @Test func sanitizerDropsInvalidTasksAndBucketsOpenBeforeArchived() {
        let duplicateId = UUID()
        let first = WorkspaceTask(id: duplicateId, title: "  Ship CLI  ", createdAt: Date(timeIntervalSince1970: 1))
        let duplicate = WorkspaceTask(id: duplicateId, title: "Duplicate", createdAt: Date(timeIntervalSince1970: 2))
        let archived = WorkspaceTask(
            id: UUID(),
            title: "  Done  ",
            createdAt: Date(timeIntervalSince1970: 3),
            archivedAt: Date(timeIntervalSince1970: 4)
        )
        let empty = WorkspaceTask(id: UUID(), title: "   ", createdAt: Date(timeIntervalSince1970: 5))

        let sanitized = Workspace.sanitizedWorkspaceTasks([archived, empty, first, duplicate])

        #expect(sanitized.map(\.id) == [first.id, archived.id])
        #expect(sanitized.map(\.title) == ["Ship CLI", "Done"])
        #expect(sanitized.map(\.isArchived) == [false, true])
    }

    @Test func addArchiveRemoveAndReorderUseOneWorkspaceOwnedList() throws {
        let workspace = Workspace(title: "Tasks")
        let first = try #require(workspace.addWorkspaceTask(
            title: "  First  ",
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        let third = try #require(workspace.addWorkspaceTask(
            title: "Third",
            createdAt: Date(timeIntervalSince1970: 3)
        ))
        let second = try #require(workspace.addWorkspaceTask(
            title: "Second",
            before: third.id,
            createdAt: Date(timeIntervalSince1970: 2)
        ))

        #expect(workspace.openWorkspaceTasks.map(\.title) == ["First", "Second", "Third"])
        #expect(workspace.addWorkspaceTask(title: "   ") == nil)

        _ = workspace.moveWorkspaceTask(id: third.id, index: 0)
        #expect(workspace.openWorkspaceTasks.map(\.id) == [third.id, first.id, second.id])

        let archived = try #require(workspace.archiveWorkspaceTask(
            id: first.id,
            archivedAt: Date(timeIntervalSince1970: 10)
        ))
        #expect(archived.archivedAt == Date(timeIntervalSince1970: 10))
        #expect(workspace.openWorkspaceTasks.map(\.id) == [third.id, second.id])
        #expect(workspace.archivedWorkspaceTasks.map(\.id) == [first.id])

        let beforeInvalidMove = workspace.workspaceTasks
        #expect(workspace.moveWorkspaceTask(id: first.id, before: second.id) == nil)
        #expect(workspace.workspaceTasks == beforeInvalidMove)

        let removed = try #require(workspace.removeWorkspaceTask(id: third.id))
        #expect(removed.id == third.id)
        #expect(workspace.openWorkspaceTasks.map(\.id) == [second.id])
        #expect(workspace.archivedWorkspaceTasks.map(\.id) == [first.id])
    }

    @Test func sessionSnapshotRoundTripsWorkspaceTasks() throws {
        let open = WorkspaceTask(
            id: UUID(),
            title: "Open",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let archived = WorkspaceTask(
            id: UUID(),
            title: "Archived",
            createdAt: Date(timeIntervalSince1970: 2),
            archivedAt: Date(timeIntervalSince1970: 3)
        )
        let snapshot = SessionWorkspaceSnapshot(
            processTitle: "zsh",
            customTitle: nil,
            customDescription: nil,
            customColor: nil,
            isPinned: false,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            tasks: [open, archived]
        )

        let decoded = try JSONDecoder().decode(
            SessionWorkspaceSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        #expect(decoded.tasks == [open, archived])
    }

    @Test func workspaceRowControlsSnapshotRespectsBetaFlags() {
        let controlsDisabled = WorkspaceRowControlsSnapshot.resolved(
            workspaceControlsBetaEnabled: false,
            workspaceTasksBetaEnabled: true,
            configuredControls: [.tasks, .close],
            fontScale: 1
        )
        #expect(controlsDisabled.controls == [.close])

        let tasksDisabled = WorkspaceRowControlsSnapshot.resolved(
            workspaceControlsBetaEnabled: true,
            workspaceTasksBetaEnabled: false,
            configuredControls: [.tasks],
            fontScale: 1
        )
        #expect(tasksDisabled.controls == [.close])

        let enabled = WorkspaceRowControlsSnapshot.resolved(
            workspaceControlsBetaEnabled: true,
            workspaceTasksBetaEnabled: true,
            configuredControls: [.tasks, .close],
            fontScale: 1
        )
        #expect(enabled.controls == [.tasks, .close])
    }

    @Test func workspaceRowControlsLayoutGrowsMinimumWidthOnlyForExtraControls() {
        let oneControl = WorkspaceRowControlsLayout.requiredMinimumSidebarWidth(
            controlCount: 1,
            fontScale: 1
        )
        let twoControls = WorkspaceRowControlsLayout.requiredMinimumSidebarWidth(
            controlCount: 2,
            fontScale: 1
        )
        let threeControls = WorkspaceRowControlsLayout.requiredMinimumSidebarWidth(
            controlCount: 3,
            fontScale: 1
        )
        let beyondCap = WorkspaceRowControlsLayout.requiredMinimumSidebarWidth(
            controlCount: 4,
            fontScale: 1
        )

        #expect(oneControl == 220)
        #expect(twoControls == 240)
        #expect(threeControls == 260)
        #expect(beyondCap == threeControls)
    }
}
