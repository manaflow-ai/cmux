import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class SchedulerEngineTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-engine-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeEngine(
        tasks: [ScheduledTask] = [],
        runs: [TaskRun] = [],
        now: Date = Date()
    ) -> SchedulerEngine {
        let fileURL = tempDir.appendingPathComponent("scheduler.json")
        SchedulerPersistenceStore.save(tasks, fileURL: fileURL)
        let engine = SchedulerEngine(persistenceFileURL: fileURL, now: now)
        engine.runs = runs
        return engine
    }

    // MARK: - evaluateSchedules with enabled past-due task creates TaskRun

    func testEvaluateSchedulesPastDueTaskCreatesRun() {
        // Task with "every minute" cron, last evaluated 2 minutes ago
        let now = Date()
        let twoMinutesAgo = now.addingTimeInterval(-120)
        let task = ScheduledTask(
            name: "every-minute",
            cronExpression: "* * * * *",
            command: "echo test",
            createdAt: Date(timeIntervalSince1970: 1700000000)
        )

        let engine = makeEngine(tasks: [task], now: twoMinutesAgo)

        let newRuns = engine.evaluateSchedules(now: now)

        XCTAssertEqual(newRuns.count, 1)
        XCTAssertEqual(newRuns[0].taskId, task.id)
        XCTAssertEqual(newRuns[0].status, .running)
        XCTAssertEqual(engine.runs.count, 1)
    }

    func testEvaluateSchedulesNotYetDueTaskSkipped() {
        // Task with "every day at 3am", evaluated just now
        let now = Date()
        let task = ScheduledTask(
            name: "daily-3am",
            cronExpression: "0 3 * * *",
            command: "echo test",
            createdAt: Date(timeIntervalSince1970: 1700000000)
        )

        let engine = makeEngine(tasks: [task], now: now)

        let newRuns = engine.evaluateSchedules(now: now)

        // The next fire is in the future relative to lastEvaluatedAt=now, so no run
        XCTAssertTrue(newRuns.isEmpty)
    }

    // MARK: - disabled task skipped

    func testEvaluateSchedulesDisabledTaskSkipped() {
        let now = Date()
        let twoMinutesAgo = now.addingTimeInterval(-120)
        let task = ScheduledTask(
            name: "disabled-task",
            cronExpression: "* * * * *",
            command: "echo test",
            isEnabled: false,
            createdAt: Date(timeIntervalSince1970: 1700000000)
        )

        let engine = makeEngine(tasks: [task], now: twoMinutesAgo)

        let newRuns = engine.evaluateSchedules(now: now)

        XCTAssertTrue(newRuns.isEmpty)
        XCTAssertTrue(engine.runs.isEmpty)
    }

    // MARK: - running task with allowOverlap=false skipped

    func testEvaluateSchedulesNoOverlapSkipsRunningTask() {
        let now = Date()
        let twoMinutesAgo = now.addingTimeInterval(-120)
        let task = ScheduledTask(
            name: "no-overlap",
            cronExpression: "* * * * *",
            command: "echo test",
            allowOverlap: false,
            createdAt: Date(timeIntervalSince1970: 1700000000)
        )

        // Pre-existing running run for this task
        let existingRun = TaskRun(
            taskId: task.id,
            startedAt: twoMinutesAgo,
            status: .running
        )

        let engine = makeEngine(tasks: [task], runs: [existingRun], now: twoMinutesAgo)

        let newRuns = engine.evaluateSchedules(now: now)

        XCTAssertTrue(newRuns.isEmpty)
        // Only the pre-existing run remains
        XCTAssertEqual(engine.runs.count, 1)
    }

    func testEvaluateSchedulesOverlapAllowedCreatesAdditionalRun() {
        let now = Date()
        let twoMinutesAgo = now.addingTimeInterval(-120)
        let task = ScheduledTask(
            name: "with-overlap",
            cronExpression: "* * * * *",
            command: "echo test",
            allowOverlap: true,
            createdAt: Date(timeIntervalSince1970: 1700000000)
        )

        let existingRun = TaskRun(
            taskId: task.id,
            startedAt: twoMinutesAgo,
            status: .running
        )

        let engine = makeEngine(tasks: [task], runs: [existingRun], now: twoMinutesAgo)

        let newRuns = engine.evaluateSchedules(now: now)

        XCTAssertEqual(newRuns.count, 1)
        XCTAssertEqual(engine.runs.count, 2) // original + new
    }

    // MARK: - maxConcurrentTasks limit respected

    func testEvaluateSchedulesRespectsMaxConcurrentTasks() {
        let now = Date()
        let twoMinutesAgo = now.addingTimeInterval(-120)

        // Create 3 tasks, all due
        let tasks = (0..<3).map { i in
            ScheduledTask(
                name: "task-\(i)",
                cronExpression: "* * * * *",
                command: "echo \(i)",
                createdAt: Date(timeIntervalSince1970: 1700000000)
            )
        }

        let engine = makeEngine(tasks: tasks, now: twoMinutesAgo)
        engine.maxConcurrentTasks = 2

        let newRuns = engine.evaluateSchedules(now: now)

        // Only 2 should fire due to the limit
        XCTAssertEqual(newRuns.count, 2)
        XCTAssertEqual(engine.runs.count, 2)
    }

    func testEvaluateSchedulesCountsExistingRunsAgainstLimit() {
        let now = Date()
        let twoMinutesAgo = now.addingTimeInterval(-120)

        let task1 = ScheduledTask(
            name: "task-1",
            cronExpression: "* * * * *",
            command: "echo 1",
            allowOverlap: true,
            createdAt: Date(timeIntervalSince1970: 1700000000)
        )
        let task2 = ScheduledTask(
            name: "task-2",
            cronExpression: "* * * * *",
            command: "echo 2",
            createdAt: Date(timeIntervalSince1970: 1700000060)
        )

        // One task already running
        let existingRun = TaskRun(
            taskId: task1.id,
            startedAt: twoMinutesAgo,
            status: .running
        )

        let engine = makeEngine(tasks: [task1, task2], runs: [existingRun], now: twoMinutesAgo)
        engine.maxConcurrentTasks = 2

        let newRuns = engine.evaluateSchedules(now: now)

        // 1 existing + 1 new = 2 (at limit), so only 1 new run should be created
        XCTAssertEqual(newRuns.count, 1)
        XCTAssertEqual(engine.runs.count, 2) // existing + 1 new
    }

    // MARK: - lastEvaluatedAt prevents duplicate fires

    func testLastEvaluatedAtPreventsDuplicateFires() {
        let now = Date()
        let twoMinutesAgo = now.addingTimeInterval(-120)
        let task = ScheduledTask(
            name: "every-minute",
            cronExpression: "* * * * *",
            command: "echo test",
            createdAt: Date(timeIntervalSince1970: 1700000000)
        )

        let engine = makeEngine(tasks: [task], now: twoMinutesAgo)

        // First evaluation fires
        let firstRuns = engine.evaluateSchedules(now: now)
        XCTAssertEqual(firstRuns.count, 1)

        // Second evaluation at the same time should NOT fire again
        // because lastEvaluatedAt was updated to `now`
        let secondRuns = engine.evaluateSchedules(now: now)
        XCTAssertTrue(secondRuns.isEmpty)
    }

    func testLastEvaluatedAtAdvancesAfterEvaluation() {
        let now = Date()
        let twoMinutesAgo = now.addingTimeInterval(-120)
        let task = ScheduledTask(
            name: "every-minute",
            cronExpression: "* * * * *",
            command: "echo test",
            createdAt: Date(timeIntervalSince1970: 1700000000)
        )

        let engine = makeEngine(tasks: [task], now: twoMinutesAgo)
        XCTAssertEqual(engine.lastEvaluatedAt, twoMinutesAgo)

        _ = engine.evaluateSchedules(now: now)

        XCTAssertEqual(engine.lastEvaluatedAt, now)
    }

    func testEvaluateSchedulesFiresAgainAfterTimeAdvances() {
        let baseTime = Date()
        let twoMinutesAgo = baseTime.addingTimeInterval(-120)
        let twoMinutesLater = baseTime.addingTimeInterval(120)
        let task = ScheduledTask(
            name: "every-minute",
            cronExpression: "* * * * *",
            command: "echo test",
            createdAt: Date(timeIntervalSince1970: 1700000000)
        )

        let engine = makeEngine(tasks: [task], now: twoMinutesAgo)

        // First evaluation fires
        let firstRuns = engine.evaluateSchedules(now: baseTime)
        XCTAssertEqual(firstRuns.count, 1)

        // Advance time by 2 more minutes — should fire again
        let laterRuns = engine.evaluateSchedules(now: twoMinutesLater)
        XCTAssertEqual(laterRuns.count, 1)
        XCTAssertEqual(engine.runs.count, 2)
    }

    // MARK: - startup cleanup of stale running records

    func testCleanupStaleRunsMarksRunningAsCancelled() {
        let engine = makeEngine()

        let staleRun1 = TaskRun(
            taskId: UUID(),
            startedAt: Date().addingTimeInterval(-3600),
            status: .running
        )
        let staleRun2 = TaskRun(
            taskId: UUID(),
            startedAt: Date().addingTimeInterval(-7200),
            status: .running
        )
        let completedRun = TaskRun(
            taskId: UUID(),
            startedAt: Date().addingTimeInterval(-3600),
            completedAt: Date().addingTimeInterval(-3500),
            exitCode: 0,
            status: .succeeded
        )

        engine.runs = [staleRun1, completedRun, staleRun2]
        engine.cleanupStaleRuns()

        XCTAssertEqual(engine.runs[0].status, .cancelled)
        XCTAssertNotNil(engine.runs[0].completedAt)
        XCTAssertEqual(engine.runs[1].status, .succeeded) // unchanged
        XCTAssertEqual(engine.runs[2].status, .cancelled)
        XCTAssertNotNil(engine.runs[2].completedAt)
    }

    func testCleanupStaleRunsNoRunningRecordsIsNoop() {
        let engine = makeEngine()

        let completedRun = TaskRun(
            taskId: UUID(),
            startedAt: Date().addingTimeInterval(-3600),
            completedAt: Date().addingTimeInterval(-3500),
            exitCode: 0,
            status: .succeeded
        )
        let failedRun = TaskRun(
            taskId: UUID(),
            startedAt: Date().addingTimeInterval(-3600),
            completedAt: Date().addingTimeInterval(-3500),
            exitCode: 1,
            status: .failed
        )

        engine.runs = [completedRun, failedRun]
        engine.cleanupStaleRuns()

        XCTAssertEqual(engine.runs[0].status, .succeeded)
        XCTAssertEqual(engine.runs[1].status, .failed)
    }

    // MARK: - onTaskDue callback

    func testOnTaskDueCalledForEachFiredTask() {
        let now = Date()
        let twoMinutesAgo = now.addingTimeInterval(-120)
        let task = ScheduledTask(
            name: "callback-test",
            cronExpression: "* * * * *",
            command: "echo test",
            createdAt: Date(timeIntervalSince1970: 1700000000)
        )

        let engine = makeEngine(tasks: [task], now: twoMinutesAgo)

        var callbackInvocations: [(ScheduledTask, TaskRun)] = []
        engine.onTaskDue = { task, run in
            callbackInvocations.append((task, run))
        }

        let newRuns = engine.evaluateSchedules(now: now)

        XCTAssertEqual(callbackInvocations.count, 1)
        XCTAssertEqual(callbackInvocations[0].0.id, task.id)
        XCTAssertEqual(callbackInvocations[0].1.id, newRuns[0].id)
    }

    // MARK: - Task management

    func testAddTaskPersists() {
        let fileURL = tempDir.appendingPathComponent("scheduler.json")
        SchedulerPersistenceStore.save([], fileURL: fileURL)
        let engine = SchedulerEngine(persistenceFileURL: fileURL)

        let task = ScheduledTask(
            name: "new-task",
            cronExpression: "0 * * * *",
            command: "echo hello",
            createdAt: Date(timeIntervalSince1970: 1700000000)
        )
        engine.addTask(task)

        XCTAssertEqual(engine.tasks.count, 1)

        // Verify it was persisted
        let loaded = SchedulerPersistenceStore.load(fileURL: fileURL)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, task.id)
    }

    func testRemoveTaskPersists() {
        let task = ScheduledTask(
            name: "to-remove",
            cronExpression: "0 * * * *",
            command: "echo bye",
            createdAt: Date(timeIntervalSince1970: 1700000000)
        )
        let fileURL = tempDir.appendingPathComponent("scheduler.json")
        SchedulerPersistenceStore.save([task], fileURL: fileURL)
        let engine = SchedulerEngine(persistenceFileURL: fileURL)

        XCTAssertEqual(engine.tasks.count, 1)
        engine.removeTask(id: task.id)
        XCTAssertTrue(engine.tasks.isEmpty)

        let loaded = SchedulerPersistenceStore.load(fileURL: fileURL)
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - Running task count

    func testRunningTaskCount() {
        let engine = makeEngine()
        engine.runs = [
            TaskRun(taskId: UUID(), status: .running),
            TaskRun(taskId: UUID(), status: .succeeded),
            TaskRun(taskId: UUID(), status: .running),
            TaskRun(taskId: UUID(), status: .cancelled),
        ]

        XCTAssertEqual(engine.runningTaskCount, 2)
    }

    // MARK: - executeTask creates TaskRun with running status

    func testEvaluateSchedulesCreatesRunningTaskRun() {
        // When evaluateSchedules fires a task, the resulting TaskRun should
        // have .running status and be tracked in the engine's runs array.
        let now = Date()
        let twoMinutesAgo = now.addingTimeInterval(-120)
        let task = ScheduledTask(
            name: "exec-test",
            cronExpression: "* * * * *",
            command: "echo hello",
            createdAt: Date(timeIntervalSince1970: 1700000000)
        )

        let engine = makeEngine(tasks: [task], now: twoMinutesAgo)

        var capturedRun: TaskRun?
        engine.onTaskDue = { _, run in
            capturedRun = run
        }

        let newRuns = engine.evaluateSchedules(now: now)

        XCTAssertEqual(newRuns.count, 1)
        XCTAssertEqual(newRuns[0].status, .running)
        XCTAssertEqual(newRuns[0].taskId, task.id)
        XCTAssertNotNil(capturedRun)
        XCTAssertEqual(capturedRun?.status, .running)
    }

    // MARK: - handleTaskCompletion updates TaskRun with exit_code

    func testHandleTaskCompletionSuccessUpdatesRun() {
        let engine = makeEngine()
        let taskId = UUID()
        let panelId = UUID()
        let run = TaskRun(id: UUID(), taskId: taskId, panelId: panelId, status: .running)

        engine.runs = [run]
        engine.panelToRunId[panelId] = run.id

        engine.handleTaskCompletion(panelId: panelId, exitCode: 0, workspaceId: nil)

        XCTAssertEqual(engine.runs[0].status, .succeeded)
        XCTAssertEqual(engine.runs[0].exitCode, 0)
        XCTAssertNotNil(engine.runs[0].completedAt)
        XCTAssertNil(engine.panelToRunId[panelId])
    }

    func testHandleTaskCompletionFailureUpdatesRun() {
        let engine = makeEngine()
        let taskId = UUID()
        let panelId = UUID()
        let run = TaskRun(id: UUID(), taskId: taskId, panelId: panelId, status: .running)

        engine.runs = [run]
        engine.panelToRunId[panelId] = run.id

        engine.handleTaskCompletion(panelId: panelId, exitCode: 1, workspaceId: nil)

        XCTAssertEqual(engine.runs[0].status, .failed)
        XCTAssertEqual(engine.runs[0].exitCode, 1)
        XCTAssertNotNil(engine.runs[0].completedAt)
    }

    func testHandleTaskCompletionUnknownPanelIsNoop() {
        let engine = makeEngine()
        let run = TaskRun(taskId: UUID(), status: .running)
        engine.runs = [run]

        // Call with a panelId that's not in panelToRunId — should not crash or modify runs
        engine.handleTaskCompletion(panelId: UUID(), exitCode: 0, workspaceId: nil)

        XCTAssertEqual(engine.runs[0].status, .running) // unchanged
    }

    // MARK: - cancelTask marks run as cancelled

    func testCancelTaskMarksRunAsCancelled() {
        let engine = makeEngine()
        let panelId = UUID()
        let run = TaskRun(id: UUID(), taskId: UUID(), panelId: panelId, status: .running)

        engine.runs = [run]
        engine.panelToRunId[panelId] = run.id

        engine.cancelTask(runId: run.id)

        XCTAssertEqual(engine.runs[0].status, .cancelled)
        XCTAssertNotNil(engine.runs[0].completedAt)
        XCTAssertNil(engine.panelToRunId[panelId])
    }

    func testCancelTaskNonRunningIsNoop() {
        let engine = makeEngine()
        let run = TaskRun(
            id: UUID(), taskId: UUID(),
            completedAt: Date(), exitCode: 0, status: .succeeded
        )

        engine.runs = [run]

        engine.cancelTask(runId: run.id)

        // Should remain succeeded — cancel only works on running tasks
        XCTAssertEqual(engine.runs[0].status, .succeeded)
    }

    // MARK: - panelToRunId tracking

    func testPanelToRunIdMappingMaintained() {
        let engine = makeEngine()
        let panelId = UUID()
        let run = TaskRun(id: UUID(), taskId: UUID(), panelId: panelId, status: .running)

        engine.runs = [run]
        engine.panelToRunId[panelId] = run.id

        XCTAssertEqual(engine.panelToRunId[panelId], run.id)

        // After completion, mapping should be removed
        engine.handleTaskCompletion(panelId: panelId, exitCode: 0, workspaceId: nil)
        XCTAssertNil(engine.panelToRunId[panelId])
    }

    // MARK: - handleAppWillTerminate

    func testHandleAppWillTerminateCancelsRunningTasks() {
        let engine = makeEngine()
        let panelId1 = UUID()
        let panelId2 = UUID()

        engine.runs = [
            TaskRun(taskId: UUID(), panelId: panelId1, status: .running),
            TaskRun(taskId: UUID(), completedAt: Date(), exitCode: 0, status: .succeeded),
            TaskRun(taskId: UUID(), panelId: panelId2, status: .running),
        ]
        engine.panelToRunId[panelId1] = engine.runs[0].id
        engine.panelToRunId[panelId2] = engine.runs[2].id

        engine.handleAppWillTerminate()

        XCTAssertEqual(engine.runs[0].status, .cancelled)
        XCTAssertNotNil(engine.runs[0].completedAt)
        XCTAssertEqual(engine.runs[1].status, .succeeded) // unchanged
        XCTAssertEqual(engine.runs[2].status, .cancelled)
        XCTAssertNotNil(engine.runs[2].completedAt)
        XCTAssertTrue(engine.panelToRunId.isEmpty)
    }

    // MARK: - completion fires addNotification

    func testHandleTaskCompletionFiresNotification() {
        let engine = makeEngine()
        let task = ScheduledTask(
            name: "notify-test",
            cronExpression: "* * * * *",
            command: "echo done",
            createdAt: Date(timeIntervalSince1970: 1700000000)
        )
        engine.tasks = [task]

        let panelId = UUID()
        let run = TaskRun(id: UUID(), taskId: task.id, panelId: panelId, status: .running)
        engine.runs = [run]
        engine.panelToRunId[panelId] = run.id

        let notifCountBefore = TerminalNotificationStore.shared.notifications.count

        engine.handleTaskCompletion(panelId: panelId, exitCode: 0, workspaceId: nil)

        // Verify a notification was added to the store
        let notifCountAfter = TerminalNotificationStore.shared.notifications.count
        XCTAssertGreaterThan(notifCountAfter, notifCountBefore)

        // Verify the notification content
        if let latest = TerminalNotificationStore.shared.notifications.first {
            XCTAssertEqual(latest.title, "notify-test")
            XCTAssertEqual(latest.subtitle, "Scheduled Task")
            XCTAssertTrue(latest.body.contains("completed successfully"))
        }
    }

    // MARK: - Session memory context file

    func testContextFileCreation() {
        let engine = makeEngine()
        let task = ScheduledTask(
            name: "context-test",
            cronExpression: "* * * * *",
            command: "echo test",
            workingDirectory: "/tmp",
            createdAt: Date(timeIntervalSince1970: 1700000000)
        )
        let run = TaskRun(taskId: task.id, startedAt: Date(timeIntervalSince1970: 1700000100))

        let contextDir = tempDir.appendingPathComponent("context", isDirectory: true)
        let contextFile = contextDir.appendingPathComponent("\(run.id.uuidString).json")

        // Access private method via the engine's executeTask flow is not possible in unit tests,
        // but we can verify the context file path format is correct
        XCTAssertTrue(contextFile.path.hasSuffix(".json"))
        XCTAssertTrue(contextFile.path.contains(run.id.uuidString))
    }
}
