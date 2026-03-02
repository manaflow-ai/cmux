import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class SchedulerSocketAPITests: XCTestCase {

    private var savedTasks: [ScheduledTask] = []
    private var savedRuns: [TaskRun] = []

    override func setUp() {
        super.setUp()
        // Save current state
        savedTasks = SchedulerEngine.shared.tasks
        savedRuns = SchedulerEngine.shared.runs
        // Clear for test isolation
        SchedulerEngine.shared.tasks = []
        SchedulerEngine.shared.runs = []
    }

    override func tearDown() {
        // Restore original state
        SchedulerEngine.shared.tasks = savedTasks
        SchedulerEngine.shared.runs = savedRuns
        super.tearDown()
    }

    // MARK: - scheduler.create with valid params returns task_id

    func testSchedulerCreateValidParams() {
        let params: [String: Any] = [
            "name": "test-task",
            "cron": "*/5 * * * *",
            "command": "echo hello"
        ]

        let result = TerminalController.shared.v2SchedulerDispatch(method: "scheduler.create", params: params)

        switch result {
        case .ok(let payload):
            let dict = payload as? [String: Any]
            XCTAssertNotNil(dict)
            XCTAssertNotNil(dict?["task_id"] as? String)
            let taskDict = dict?["task"] as? [String: Any]
            XCTAssertEqual(taskDict?["name"] as? String, "test-task")
            XCTAssertEqual(taskDict?["cron"] as? String, "*/5 * * * *")
            XCTAssertEqual(taskDict?["command"] as? String, "echo hello")
            XCTAssertEqual(taskDict?["is_enabled"] as? Bool, true)
        case .err:
            XCTFail("Expected .ok but got .err")
        }

        // Verify task was added to engine
        XCTAssertEqual(SchedulerEngine.shared.tasks.count, 1)
        XCTAssertEqual(SchedulerEngine.shared.tasks[0].name, "test-task")
    }

    func testSchedulerCreateWithAllOptionalParams() {
        let params: [String: Any] = [
            "name": "full-task",
            "cron": "0 9 * * 1-5",
            "command": "make build",
            "working_directory": "/tmp/project",
            "environment": ["CI": "true"],
            "is_enabled": false,
            "allow_overlap": true,
            "use_worktree": true,
            "on_success": "deploy",
            "on_failure": "notify"
        ]

        let result = TerminalController.shared.v2SchedulerDispatch(method: "scheduler.create", params: params)

        switch result {
        case .ok(let payload):
            let dict = payload as? [String: Any]
            let taskDict = dict?["task"] as? [String: Any]
            XCTAssertEqual(taskDict?["name"] as? String, "full-task")
            XCTAssertEqual(taskDict?["is_enabled"] as? Bool, false)
            XCTAssertEqual(taskDict?["allow_overlap"] as? Bool, true)
            XCTAssertEqual(taskDict?["use_worktree"] as? Bool, true)
            XCTAssertEqual(taskDict?["working_directory"] as? String, "/tmp/project")
            XCTAssertEqual(taskDict?["on_success"] as? String, "deploy")
            XCTAssertEqual(taskDict?["on_failure"] as? String, "notify")
        case .err:
            XCTFail("Expected .ok but got .err")
        }
    }

    // MARK: - scheduler.create with invalid cron returns error

    func testSchedulerCreateInvalidCron() {
        let params: [String: Any] = [
            "name": "bad-cron",
            "cron": "not a cron",
            "command": "echo hello"
        ]

        let result = TerminalController.shared.v2SchedulerDispatch(method: "scheduler.create", params: params)

        switch result {
        case .ok:
            XCTFail("Expected .err but got .ok")
        case .err(let code, let message, _):
            XCTAssertEqual(code, "invalid_cron")
            XCTAssertTrue(message.contains("Invalid cron"))
        }

        // Verify no task was added
        XCTAssertTrue(SchedulerEngine.shared.tasks.isEmpty)
    }

    func testSchedulerCreateMissingName() {
        let params: [String: Any] = [
            "cron": "* * * * *",
            "command": "echo hello"
        ]

        let result = TerminalController.shared.v2SchedulerDispatch(method: "scheduler.create", params: params)

        switch result {
        case .ok:
            XCTFail("Expected .err for missing name")
        case .err(let code, _, _):
            XCTAssertEqual(code, "invalid_params")
        }
    }

    func testSchedulerCreateMissingCommand() {
        let params: [String: Any] = [
            "name": "test",
            "cron": "* * * * *"
        ]

        let result = TerminalController.shared.v2SchedulerDispatch(method: "scheduler.create", params: params)

        switch result {
        case .ok:
            XCTFail("Expected .err for missing command")
        case .err(let code, _, _):
            XCTAssertEqual(code, "invalid_params")
        }
    }

    // MARK: - scheduler.list returns all tasks

    func testSchedulerListEmpty() {
        let result = TerminalController.shared.v2SchedulerDispatch(method: "scheduler.list", params: [:])

        switch result {
        case .ok(let payload):
            let dict = payload as? [String: Any]
            XCTAssertEqual(dict?["count"] as? Int, 0)
            let tasks = dict?["tasks"] as? [[String: Any]]
            XCTAssertNotNil(tasks)
            XCTAssertTrue(tasks?.isEmpty ?? false)
        case .err:
            XCTFail("Expected .ok but got .err")
        }
    }

    func testSchedulerListWithTasks() {
        // Add some tasks
        let task1 = ScheduledTask(
            name: "task-one",
            cronExpression: "* * * * *",
            command: "echo 1"
        )
        let task2 = ScheduledTask(
            name: "task-two",
            cronExpression: "0 * * * *",
            command: "echo 2"
        )
        SchedulerEngine.shared.tasks = [task1, task2]

        let result = TerminalController.shared.v2SchedulerDispatch(method: "scheduler.list", params: [:])

        switch result {
        case .ok(let payload):
            let dict = payload as? [String: Any]
            XCTAssertEqual(dict?["count"] as? Int, 2)
            let tasks = dict?["tasks"] as? [[String: Any]]
            XCTAssertEqual(tasks?.count, 2)
            XCTAssertEqual(tasks?[0]["name"] as? String, "task-one")
            XCTAssertEqual(tasks?[1]["name"] as? String, "task-two")
        case .err:
            XCTFail("Expected .ok but got .err")
        }
    }

    func testSchedulerListIncludesLastRunInfo() {
        let task = ScheduledTask(
            name: "with-runs",
            cronExpression: "* * * * *",
            command: "echo test"
        )
        SchedulerEngine.shared.tasks = [task]

        let run = TaskRun(
            taskId: task.id,
            startedAt: Date().addingTimeInterval(-60),
            completedAt: Date(),
            exitCode: 0,
            status: .succeeded
        )
        SchedulerEngine.shared.runs = [run]

        let result = TerminalController.shared.v2SchedulerDispatch(method: "scheduler.list", params: [:])

        switch result {
        case .ok(let payload):
            let dict = payload as? [String: Any]
            let tasks = dict?["tasks"] as? [[String: Any]]
            let lastRun = tasks?[0]["last_run"] as? [String: Any]
            XCTAssertNotNil(lastRun)
            XCTAssertEqual(lastRun?["status"] as? String, "succeeded")
            XCTAssertEqual(lastRun?["exit_code"] as? Int32, 0)
        case .err:
            XCTFail("Expected .ok but got .err")
        }
    }

    // MARK: - scheduler.delete

    func testSchedulerDeleteExistingTask() {
        let task = ScheduledTask(
            name: "to-delete",
            cronExpression: "* * * * *",
            command: "echo bye"
        )
        SchedulerEngine.shared.tasks = [task]

        let params: [String: Any] = ["task_id": task.id.uuidString]
        let result = TerminalController.shared.v2SchedulerDispatch(method: "scheduler.delete", params: params)

        switch result {
        case .ok(let payload):
            let dict = payload as? [String: Any]
            XCTAssertEqual(dict?["deleted"] as? Bool, true)
        case .err:
            XCTFail("Expected .ok but got .err")
        }

        XCTAssertTrue(SchedulerEngine.shared.tasks.isEmpty)
    }

    func testSchedulerDeleteNonexistentTask() {
        let params: [String: Any] = ["task_id": UUID().uuidString]
        let result = TerminalController.shared.v2SchedulerDispatch(method: "scheduler.delete", params: params)

        switch result {
        case .ok:
            XCTFail("Expected .err for nonexistent task")
        case .err(let code, _, _):
            XCTAssertEqual(code, "not_found")
        }
    }

    // MARK: - scheduler.update

    func testSchedulerUpdateName() {
        let task = ScheduledTask(
            name: "old-name",
            cronExpression: "* * * * *",
            command: "echo test"
        )
        SchedulerEngine.shared.tasks = [task]

        let params: [String: Any] = [
            "task_id": task.id.uuidString,
            "name": "new-name"
        ]
        let result = TerminalController.shared.v2SchedulerDispatch(method: "scheduler.update", params: params)

        switch result {
        case .ok(let payload):
            let dict = payload as? [String: Any]
            let taskDict = dict?["task"] as? [String: Any]
            XCTAssertEqual(taskDict?["name"] as? String, "new-name")
        case .err:
            XCTFail("Expected .ok but got .err")
        }

        XCTAssertEqual(SchedulerEngine.shared.tasks[0].name, "new-name")
    }

    func testSchedulerUpdateInvalidCron() {
        let task = ScheduledTask(
            name: "test",
            cronExpression: "* * * * *",
            command: "echo test"
        )
        SchedulerEngine.shared.tasks = [task]

        let params: [String: Any] = [
            "task_id": task.id.uuidString,
            "cron": "invalid cron"
        ]
        let result = TerminalController.shared.v2SchedulerDispatch(method: "scheduler.update", params: params)

        switch result {
        case .ok:
            XCTFail("Expected .err for invalid cron")
        case .err(let code, _, _):
            XCTAssertEqual(code, "invalid_cron")
        }

        // Verify original cron is unchanged
        XCTAssertEqual(SchedulerEngine.shared.tasks[0].cronExpression, "* * * * *")
    }

    // MARK: - scheduler.enable / scheduler.disable

    func testSchedulerEnableDisable() {
        let task = ScheduledTask(
            name: "toggle-test",
            cronExpression: "* * * * *",
            command: "echo test",
            isEnabled: false
        )
        SchedulerEngine.shared.tasks = [task]

        // Enable
        let enableResult = TerminalController.shared.v2SchedulerDispatch(
            method: "scheduler.enable",
            params: ["task_id": task.id.uuidString]
        )
        switch enableResult {
        case .ok(let payload):
            let dict = payload as? [String: Any]
            XCTAssertEqual(dict?["is_enabled"] as? Bool, true)
        case .err:
            XCTFail("Expected .ok but got .err")
        }
        XCTAssertTrue(SchedulerEngine.shared.tasks[0].isEnabled)

        // Disable
        let disableResult = TerminalController.shared.v2SchedulerDispatch(
            method: "scheduler.disable",
            params: ["task_id": task.id.uuidString]
        )
        switch disableResult {
        case .ok(let payload):
            let dict = payload as? [String: Any]
            XCTAssertEqual(dict?["is_enabled"] as? Bool, false)
        case .err:
            XCTFail("Expected .ok but got .err")
        }
        XCTAssertFalse(SchedulerEngine.shared.tasks[0].isEnabled)
    }

    // MARK: - scheduler.run

    func testSchedulerRunCreatesRun() {
        let task = ScheduledTask(
            name: "run-test",
            cronExpression: "0 3 * * *",
            command: "echo run"
        )
        SchedulerEngine.shared.tasks = [task]

        // Capture onTaskDue callback
        var callbackCalled = false
        let savedCallback = SchedulerEngine.shared.onTaskDue
        SchedulerEngine.shared.onTaskDue = { _, _ in
            callbackCalled = true
        }
        defer { SchedulerEngine.shared.onTaskDue = savedCallback }

        let result = TerminalController.shared.v2SchedulerDispatch(
            method: "scheduler.run",
            params: ["task_id": task.id.uuidString]
        )

        switch result {
        case .ok(let payload):
            let dict = payload as? [String: Any]
            XCTAssertNotNil(dict?["run_id"] as? String)
            let runDict = dict?["run"] as? [String: Any]
            XCTAssertEqual(runDict?["status"] as? String, "running")
        case .err:
            XCTFail("Expected .ok but got .err")
        }

        XCTAssertTrue(callbackCalled)
        XCTAssertEqual(SchedulerEngine.shared.runs.count, 1)
    }

    func testSchedulerRunRejectsOverlap() {
        let task = ScheduledTask(
            name: "no-overlap",
            cronExpression: "* * * * *",
            command: "echo test",
            allowOverlap: false
        )
        SchedulerEngine.shared.tasks = [task]
        SchedulerEngine.shared.runs = [
            TaskRun(taskId: task.id, status: .running)
        ]

        let result = TerminalController.shared.v2SchedulerDispatch(
            method: "scheduler.run",
            params: ["task_id": task.id.uuidString]
        )

        switch result {
        case .ok:
            XCTFail("Expected .err for overlap")
        case .err(let code, _, _):
            XCTAssertEqual(code, "already_running")
        }
    }

    // MARK: - scheduler.cancel

    func testSchedulerCancelRunning() {
        let task = ScheduledTask(
            name: "cancel-test",
            cronExpression: "* * * * *",
            command: "echo test"
        )
        let run = TaskRun(taskId: task.id, status: .running)
        SchedulerEngine.shared.tasks = [task]
        SchedulerEngine.shared.runs = [run]

        let result = TerminalController.shared.v2SchedulerDispatch(
            method: "scheduler.cancel",
            params: ["run_id": run.id.uuidString]
        )

        switch result {
        case .ok(let payload):
            let dict = payload as? [String: Any]
            XCTAssertEqual(dict?["cancelled"] as? Bool, true)
        case .err:
            XCTFail("Expected .ok but got .err")
        }

        XCTAssertEqual(SchedulerEngine.shared.runs[0].status, .cancelled)
    }

    func testSchedulerCancelNotRunning() {
        let run = TaskRun(
            taskId: UUID(),
            completedAt: Date(),
            exitCode: 0,
            status: .succeeded
        )
        SchedulerEngine.shared.runs = [run]

        let result = TerminalController.shared.v2SchedulerDispatch(
            method: "scheduler.cancel",
            params: ["run_id": run.id.uuidString]
        )

        switch result {
        case .ok:
            XCTFail("Expected .err for non-running run")
        case .err(let code, _, _):
            XCTAssertEqual(code, "invalid_state")
        }
    }

    // MARK: - scheduler.logs

    func testSchedulerLogsReturnsRuns() {
        let taskId = UUID()
        let runs = [
            TaskRun(taskId: taskId, startedAt: Date().addingTimeInterval(-120), completedAt: Date().addingTimeInterval(-60), exitCode: 0, status: .succeeded),
            TaskRun(taskId: taskId, startedAt: Date().addingTimeInterval(-60), status: .running),
        ]
        SchedulerEngine.shared.runs = runs

        let result = TerminalController.shared.v2SchedulerDispatch(
            method: "scheduler.logs",
            params: ["task_id": taskId.uuidString]
        )

        switch result {
        case .ok(let payload):
            let dict = payload as? [String: Any]
            XCTAssertEqual(dict?["count"] as? Int, 2)
            let runList = dict?["runs"] as? [[String: Any]]
            XCTAssertEqual(runList?.count, 2)
            // Should be sorted by startedAt descending (most recent first)
            XCTAssertEqual(runList?[0]["status"] as? String, "running")
            XCTAssertEqual(runList?[1]["status"] as? String, "succeeded")
        case .err:
            XCTFail("Expected .ok but got .err")
        }
    }

    func testSchedulerLogsFilterByStatus() {
        let taskId = UUID()
        SchedulerEngine.shared.runs = [
            TaskRun(taskId: taskId, completedAt: Date(), exitCode: 0, status: .succeeded),
            TaskRun(taskId: taskId, status: .running),
            TaskRun(taskId: taskId, completedAt: Date(), exitCode: 1, status: .failed),
        ]

        let result = TerminalController.shared.v2SchedulerDispatch(
            method: "scheduler.logs",
            params: ["status": "running"]
        )

        switch result {
        case .ok(let payload):
            let dict = payload as? [String: Any]
            XCTAssertEqual(dict?["count"] as? Int, 1)
        case .err:
            XCTFail("Expected .ok but got .err")
        }
    }

    func testSchedulerLogsWithLimit() {
        let taskId = UUID()
        SchedulerEngine.shared.runs = (0..<10).map { i in
            TaskRun(
                taskId: taskId,
                startedAt: Date().addingTimeInterval(Double(-i * 60)),
                completedAt: Date(),
                exitCode: 0,
                status: .succeeded
            )
        }

        let result = TerminalController.shared.v2SchedulerDispatch(
            method: "scheduler.logs",
            params: ["limit": 3]
        )

        switch result {
        case .ok(let payload):
            let dict = payload as? [String: Any]
            XCTAssertEqual(dict?["count"] as? Int, 3)
        case .err:
            XCTFail("Expected .ok but got .err")
        }
    }

    // MARK: - scheduler.snapshot error paths

    func testSchedulerSnapshotMissingRunId() {
        let result = TerminalController.shared.v2SchedulerDispatch(
            method: "scheduler.snapshot",
            params: [:]
        )

        switch result {
        case .ok:
            XCTFail("Expected .err for missing run_id")
        case .err(let code, _, _):
            XCTAssertEqual(code, "invalid_params")
        }
    }

    func testSchedulerSnapshotRunNotFound() {
        let result = TerminalController.shared.v2SchedulerDispatch(
            method: "scheduler.snapshot",
            params: ["run_id": UUID().uuidString]
        )

        switch result {
        case .ok:
            XCTFail("Expected .err for nonexistent run")
        case .err(let code, _, _):
            XCTAssertEqual(code, "not_found")
        }
    }

    func testSchedulerSnapshotRunWithNoPanelId() {
        let run = TaskRun(taskId: UUID(), status: .running)
        SchedulerEngine.shared.runs = [run]

        let result = TerminalController.shared.v2SchedulerDispatch(
            method: "scheduler.snapshot",
            params: ["run_id": run.id.uuidString]
        )

        switch result {
        case .ok:
            XCTFail("Expected .err for no panel")
        case .err(let code, _, _):
            XCTAssertEqual(code, "no_surface")
        }
    }

    // MARK: - Unknown scheduler method

    func testUnknownSchedulerMethod() {
        let result = TerminalController.shared.v2SchedulerDispatch(
            method: "scheduler.nonexistent",
            params: [:]
        )

        switch result {
        case .ok:
            XCTFail("Expected .err for unknown method")
        case .err(let code, _, _):
            XCTAssertEqual(code, "method_not_found")
        }
    }
}
