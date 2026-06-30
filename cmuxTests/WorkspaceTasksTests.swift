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

    @Test func sanitizerBoundsTitlesAndTaskBuckets() {
        var longTitleTask = WorkspaceTask(
            id: UUID(),
            title: "Temporary",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        longTitleTask.title = String(repeating: "x", count: WorkspaceTask.maximumTitleCharacters + 20)
        let openOverflow = (0..<(WorkspaceTask.maximumOpenTaskCount + 5)).map { index in
            WorkspaceTask(
                id: UUID(),
                title: "Open \(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index + 2))
            )
        }
        let archivedOverflow = (0..<(WorkspaceTask.maximumArchivedTaskCount + 5)).map { index in
            WorkspaceTask(
                id: UUID(),
                title: "Archived \(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index + 1_000)),
                archivedAt: Date(timeIntervalSince1970: TimeInterval(index + 2_000))
            )
        }

        let sanitized = Workspace.sanitizedWorkspaceTasks([longTitleTask] + archivedOverflow + openOverflow)

        #expect(sanitized.count == WorkspaceTask.maximumStoredTaskCount)
        #expect(sanitized.allSatisfy { $0.title.count <= WorkspaceTask.maximumTitleCharacters })
        #expect(sanitized.filter(\.isOpen).count == WorkspaceTask.maximumOpenTaskCount)
        #expect(sanitized.filter(\.isArchived).count == WorkspaceTask.maximumArchivedTaskCount)
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
        #expect(workspace.addWorkspaceTask(title: String(repeating: "x", count: WorkspaceTask.maximumTitleCharacters + 1)) == nil)

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
        #expect(workspace.moveWorkspaceTask(id: first.id) == nil)
        #expect(workspace.workspaceTasks == beforeInvalidMove)

        let missingAnchor = UUID()
        let beforeInvalidAdd = workspace.workspaceTasks
        #expect(workspace.addWorkspaceTask(title: "Invalid before", before: missingAnchor) == nil)
        #expect(workspace.workspaceTasks == beforeInvalidAdd)
        #expect(workspace.addWorkspaceTask(title: "Invalid after", after: missingAnchor) == nil)
        #expect(workspace.workspaceTasks == beforeInvalidAdd)

        let removed = try #require(workspace.removeWorkspaceTask(id: third.id))
        #expect(removed.id == third.id)
        #expect(workspace.openWorkspaceTasks.map(\.id) == [second.id])
        #expect(workspace.archivedWorkspaceTasks.map(\.id) == [first.id])

        let restored = try #require(workspace.unarchiveWorkspaceTask(id: first.id))
        #expect(restored.archivedAt == nil)
        #expect(workspace.openWorkspaceTasks.map(\.id) == [second.id, first.id])
        #expect(workspace.archivedWorkspaceTasks.isEmpty)
    }

    @Test func addArchiveAndUnarchiveRespectTaskCountCaps() throws {
        let workspace = Workspace(title: "Tasks")
        workspace.workspaceTasks = (0..<WorkspaceTask.maximumOpenTaskCount).map { index in
            WorkspaceTask(
                id: UUID(),
                title: "Open \(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        #expect(workspace.addWorkspaceTask(title: "Overflow") == nil)

        let openTask = try #require(workspace.workspaceTasks.first)
        workspace.workspaceTasks = [openTask] + (0..<WorkspaceTask.maximumArchivedTaskCount).map { index in
            WorkspaceTask(
                id: UUID(),
                title: "Archived \(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index + 1_000)),
                archivedAt: Date(timeIntervalSince1970: TimeInterval(index + 2_000))
            )
        }
        #expect(workspace.archiveWorkspaceTask(id: openTask.id) == nil)

        let archivedTask = WorkspaceTask(
            id: UUID(),
            title: "Archived overflow",
            createdAt: Date(timeIntervalSince1970: 5_000),
            archivedAt: Date(timeIntervalSince1970: 6_000)
        )
        workspace.workspaceTasks = (0..<WorkspaceTask.maximumOpenTaskCount).map { index in
            WorkspaceTask(
                id: UUID(),
                title: "Open \(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        } + [archivedTask]
        #expect(workspace.unarchiveWorkspaceTask(id: archivedTask.id) == nil)
    }

    @Test func socketArchiveReportsLimitWhenArchiveBucketIsFull() throws {
        try withWorkspaceTasksBetaEnabled {
            let tabManager = TabManager()
            let workspace = tabManager.addWorkspace(select: true, eagerLoadTerminal: false)
            TerminalController.shared.setActiveTabManager(tabManager)
            defer { TerminalController.shared.setActiveTabManager(nil) }

            let openTask = WorkspaceTask(
                id: UUID(),
                title: "Open",
                createdAt: Date(timeIntervalSince1970: 1)
            )
            workspace.workspaceTasks = [openTask] + (0..<WorkspaceTask.maximumArchivedTaskCount).map { index in
                WorkspaceTask(
                    id: UUID(),
                    title: "Archived \(index)",
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index + 1_000)),
                    archivedAt: Date(timeIntervalSince1970: TimeInterval(index + 2_000))
                )
            }

            let result = TerminalController.shared.v2WorkspaceTasksArchive(params: [
                "workspace_id": workspace.id.uuidString,
                "task_id": openTask.id.uuidString
            ])

            guard case let .err(code, _, data) = result else {
                Issue.record("Expected archive limit error, got \(result)")
                return
            }
            #expect(code == "limit_exceeded")
            let payload = try #require(data as? [String: Any])
            #expect(payload["maximum_archived_tasks"] as? Int == WorkspaceTask.maximumArchivedTaskCount)
        }
    }

    @Test func socketUnarchiveReportsLimitWhenOpenBucketIsFull() throws {
        try withWorkspaceTasksBetaEnabled {
            let tabManager = TabManager()
            let workspace = tabManager.addWorkspace(select: true, eagerLoadTerminal: false)
            TerminalController.shared.setActiveTabManager(tabManager)
            defer { TerminalController.shared.setActiveTabManager(nil) }

            let archivedTask = WorkspaceTask(
                id: UUID(),
                title: "Archived",
                createdAt: Date(timeIntervalSince1970: 1),
                archivedAt: Date(timeIntervalSince1970: 2)
            )
            workspace.workspaceTasks = (0..<WorkspaceTask.maximumOpenTaskCount).map { index in
                WorkspaceTask(
                    id: UUID(),
                    title: "Open \(index)",
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index + 10))
                )
            } + [archivedTask]

            let result = TerminalController.shared.v2WorkspaceTasksUnarchive(params: [
                "workspace_id": workspace.id.uuidString,
                "task_id": archivedTask.id.uuidString
            ])

            guard case let .err(code, _, data) = result else {
                Issue.record("Expected unarchive limit error, got \(result)")
                return
            }
            #expect(code == "limit_exceeded")
            let payload = try #require(data as? [String: Any])
            #expect(payload["maximum_open_tasks"] as? Int == WorkspaceTask.maximumOpenTaskCount)
        }
    }

    @Test func socketMoveMissingAnchorReportsAnchorInsteadOfSubject() throws {
        try withWorkspaceTasksBetaEnabled {
            let tabManager = TabManager()
            let workspace = tabManager.addWorkspace(select: true, eagerLoadTerminal: false)
            TerminalController.shared.setActiveTabManager(tabManager)
            defer { TerminalController.shared.setActiveTabManager(nil) }

            let task = try #require(workspace.addWorkspaceTask(title: "Task"))
            let missingAnchor = UUID()

            let result = TerminalController.shared.v2WorkspaceTasksMove(params: [
                "workspace_id": workspace.id.uuidString,
                "task_id": task.id.uuidString,
                "before_task_id": missingAnchor.uuidString
            ])

            guard case let .err(code, _, data) = result else {
                Issue.record("Expected missing anchor error, got \(result)")
                return
            }
            #expect(code == "not_found")
            let payload = try #require(data as? [String: Any])
            #expect(payload["before_task_id"] as? String == missingAnchor.uuidString)
            #expect(payload["task_id"] as? String == nil)
        }
    }

    @Test func socketPlacementIndexRejectsFractionalAndBooleanValues() throws {
        try withWorkspaceTasksBetaEnabled {
            let invalidValues: [(label: String, value: Any)] = [
                ("fractional", NSNumber(value: 1.5)),
                ("boolean", NSNumber(value: true))
            ]
            let workspaceId = UUID().uuidString
            let taskId = UUID().uuidString

            for invalidValue in invalidValues {
                let addResult = TerminalController.shared.v2WorkspaceTasksAdd(params: [
                    "workspace_id": workspaceId,
                    "title": "Invalid \(invalidValue.label)",
                    "index": invalidValue.value
                ])
                guard case let .err(addCode, _, _) = addResult else {
                    Issue.record("Expected invalid add index error, got \(addResult)")
                    continue
                }
                #expect(addCode == "invalid_params")

                let moveResult = TerminalController.shared.v2WorkspaceTasksMove(params: [
                    "workspace_id": workspaceId,
                    "task_id": taskId,
                    "index": invalidValue.value
                ])
                guard case let .err(moveCode, _, _) = moveResult else {
                    Issue.record("Expected invalid move index error, got \(moveResult)")
                    continue
                }
                #expect(moveCode == "invalid_params")
            }
        }
    }

    @Test func detachedWorkspaceTasksSurfaceRebindsToDestinationWorkspace() throws {
        let key = SettingCatalog().betaFeatures.workspaceTasks.userDefaultsKey
        let previousValue = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let previousValue {
                UserDefaults.standard.set(previousValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let source = Workspace(title: "Source")
        let destination = Workspace(title: "Destination")
        let sourcePane = try #require(source.bonsplitController.focusedPaneId)
        let destinationPane = try #require(destination.bonsplitController.focusedPaneId)
        let tasksPanel = try #require(source.newWorkspaceTasksSurface(inPane: sourcePane, focus: false))
        #expect(tasksPanel.workspace?.id == source.id)

        let detached = try #require(source.detachSurface(panelId: tasksPanel.id))
        let attachedPanelId = destination.attachDetachedSurface(
            detached,
            inPane: destinationPane,
            focus: false
        )

        #expect(attachedPanelId == tasksPanel.id)
        #expect(tasksPanel.workspace?.id == destination.id)
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
        #expect(controlsDisabled.controls == [.tasks, .close])

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

    @Test func workspaceTaskSidebarStatusSummarizesOpenAndCompletedState() {
        let empty = WorkspaceTaskSidebarStatus(openCount: 0, archivedCount: 0)
        #expect(!empty.hasTasks)
        #expect(!empty.isComplete)

        let open = WorkspaceTaskSidebarStatus(openCount: 3, archivedCount: 4)
        #expect(open.hasTasks)
        #expect(!open.isComplete)
        #expect(open.openCountDisplayText == "3")

        let capped = WorkspaceTaskSidebarStatus(openCount: 120, archivedCount: 0)
        #expect(capped.openCountDisplayText == "99+")

        let complete = WorkspaceTaskSidebarStatus(openCount: 0, archivedCount: 2)
        #expect(complete.hasTasks)
        #expect(complete.isComplete)
    }

    @Test func workspaceRowControlsLayoutKeepsMinimumWidthWhenControlsIncrease() {
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
        #expect(twoControls == 220)
        #expect(threeControls == 220)
        #expect(beyondCap == 220)
    }

    private func withWorkspaceTasksBetaEnabled(_ body: () throws -> Void) rethrows {
        let key = SettingCatalog().betaFeatures.workspaceTasks.userDefaultsKey
        let previousValue = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let previousValue {
                UserDefaults.standard.set(previousValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try body()
    }
}
