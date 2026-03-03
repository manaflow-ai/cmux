import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests for the scheduler CLI integration layer.
/// These verify that v2 API responses produce valid JSON for the CLI's --json output mode,
/// and that create/list round-trips produce the expected data shapes.
@MainActor
final class SchedulerCLITests: XCTestCase {

    private var savedTasks: [ScheduledTask] = []
    private var savedRuns: [TaskRun] = []

    override func setUp() {
        super.setUp()
        savedTasks = SchedulerEngine.shared.tasks
        savedRuns = SchedulerEngine.shared.runs
        SchedulerEngine.shared.tasks = []
        SchedulerEngine.shared.runs = []
    }

    override func tearDown() {
        SchedulerEngine.shared.tasks = savedTasks
        SchedulerEngine.shared.runs = savedRuns
        super.tearDown()
    }

    // MARK: - scheduler list --json returns valid JSON

    func testSchedulerListResponseIsValidJSON() {
        // Add a task so the list is non-empty
        let task = ScheduledTask(
            name: "json-test",
            cronExpression: "*/10 * * * *",
            command: "echo json"
        )
        SchedulerEngine.shared.addTask(task)

        let result = TerminalController.shared.v2SchedulerDispatch(method: "scheduler.list", params: [:])

        switch result {
        case .ok(let payload):
            // The CLI --json flag calls jsonString() which uses JSONSerialization.
            // Verify the payload is a valid JSON object.
            guard let dict = payload as? [String: Any] else {
                XCTFail("Expected dictionary payload")
                return
            }
            XCTAssertTrue(JSONSerialization.isValidJSONObject(dict), "List response must be valid JSON")

            // Verify the serialized JSON contains expected keys
            guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
                  let jsonString = String(data: data, encoding: .utf8) else {
                XCTFail("Failed to serialize list response to JSON string")
                return
            }
            XCTAssertTrue(jsonString.contains("\"tasks\""), "JSON should contain 'tasks' key")
            XCTAssertTrue(jsonString.contains("\"count\""), "JSON should contain 'count' key")
            XCTAssertTrue(jsonString.contains("json-test"), "JSON should contain task name")

            // Verify count matches
            XCTAssertEqual(dict["count"] as? Int, 1)
        case .err(let code, let msg, _):
            XCTFail("Expected .ok but got .err(\(code): \(msg))")
        }
    }

    func testSchedulerListEmptyResponseIsValidJSON() {
        let result = TerminalController.shared.v2SchedulerDispatch(method: "scheduler.list", params: [:])

        switch result {
        case .ok(let payload):
            guard let dict = payload as? [String: Any] else {
                XCTFail("Expected dictionary payload")
                return
            }
            XCTAssertTrue(JSONSerialization.isValidJSONObject(dict))
            XCTAssertEqual(dict["count"] as? Int, 0)
            let tasks = dict["tasks"] as? [[String: Any]]
            XCTAssertNotNil(tasks)
            XCTAssertTrue(tasks?.isEmpty ?? false)
        case .err(let code, let msg, _):
            XCTFail("Expected .ok but got .err(\(code): \(msg))")
        }
    }

    // MARK: - scheduler create with valid args succeeds

    func testSchedulerCreateValidArgsProducesTaskId() {
        // Simulate what the CLI does: build params from --name/--cron/--command flags
        let params: [String: Any] = [
            "name": "cli-created-task",
            "cron": "0 * * * *",
            "command": "echo hello from cli"
        ]

        let result = TerminalController.shared.v2SchedulerDispatch(method: "scheduler.create", params: params)

        switch result {
        case .ok(let payload):
            guard let dict = payload as? [String: Any] else {
                XCTFail("Expected dictionary payload")
                return
            }
            // CLI prints task_id in non-JSON mode
            let taskId = dict["task_id"] as? String
            XCTAssertNotNil(taskId, "Create response must include task_id")
            XCTAssertFalse(taskId?.isEmpty ?? true, "task_id must not be empty")

            // Verify it's a valid UUID
            XCTAssertNotNil(UUID(uuidString: taskId ?? ""), "task_id must be a valid UUID")

            // The full response (for --json mode) must be valid JSON
            XCTAssertTrue(JSONSerialization.isValidJSONObject(dict))

            // Verify task dict is included
            let taskDict = dict["task"] as? [String: Any]
            XCTAssertNotNil(taskDict, "Create response must include task details")
            XCTAssertEqual(taskDict?["name"] as? String, "cli-created-task")
            XCTAssertEqual(taskDict?["command"] as? String, "echo hello from cli")
            XCTAssertEqual(taskDict?["cron"] as? String, "0 * * * *")
        case .err(let code, let msg, _):
            XCTFail("Expected .ok but got .err(\(code): \(msg))")
        }

        // Verify the task was actually added to the engine
        XCTAssertEqual(SchedulerEngine.shared.tasks.count, 1)
    }

    func testSchedulerCreateWithOptionalFlagsSucceeds() {
        // Simulate CLI flags: --disabled, --allow-overlap, --use-worktree, --on-success, --on-failure
        let params: [String: Any] = [
            "name": "full-cli-task",
            "cron": "30 9 * * 1-5",
            "command": "make test",
            "working_directory": "/tmp/project",
            "is_enabled": false,
            "allow_overlap": true,
            "use_worktree": true,
            "on_success": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
            "on_failure": "B2C3D4E5-F6A7-8901-BCDE-F12345678901"
        ]

        let result = TerminalController.shared.v2SchedulerDispatch(method: "scheduler.create", params: params)

        switch result {
        case .ok(let payload):
            guard let dict = payload as? [String: Any] else {
                XCTFail("Expected dictionary payload")
                return
            }
            XCTAssertTrue(JSONSerialization.isValidJSONObject(dict))

            let taskDict = dict["task"] as? [String: Any]
            XCTAssertEqual(taskDict?["is_enabled"] as? Bool, false)
            XCTAssertEqual(taskDict?["allow_overlap"] as? Bool, true)
            XCTAssertEqual(taskDict?["use_worktree"] as? Bool, true)
            XCTAssertEqual(taskDict?["on_success"] as? String, "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")
            XCTAssertEqual(taskDict?["on_failure"] as? String, "B2C3D4E5-F6A7-8901-BCDE-F12345678901")
            XCTAssertEqual(taskDict?["working_directory"] as? String, "/tmp/project")
        case .err(let code, let msg, _):
            XCTFail("Expected .ok but got .err(\(code): \(msg))")
        }
    }

    func testSchedulerCreateInvalidCronFromCLI() {
        let params: [String: Any] = [
            "name": "bad-cron",
            "cron": "not-valid",
            "command": "echo fail"
        ]

        let result = TerminalController.shared.v2SchedulerDispatch(method: "scheduler.create", params: params)

        switch result {
        case .ok:
            XCTFail("Expected .err for invalid cron expression")
        case .err(let code, _, _):
            XCTAssertEqual(code, "invalid_cron")
        }

        XCTAssertTrue(SchedulerEngine.shared.tasks.isEmpty, "No task should be created with invalid cron")
    }

    // MARK: - Round-trip: create then list

    func testSchedulerCreateThenListRoundTrip() {
        // Create
        let createParams: [String: Any] = [
            "name": "roundtrip-task",
            "cron": "*/15 * * * *",
            "command": "echo roundtrip"
        ]
        let createResult = TerminalController.shared.v2SchedulerDispatch(method: "scheduler.create", params: createParams)

        var createdTaskId: String?
        if case .ok(let payload) = createResult {
            createdTaskId = (payload as? [String: Any])?["task_id"] as? String
        }
        XCTAssertNotNil(createdTaskId)

        // List and verify
        let listResult = TerminalController.shared.v2SchedulerDispatch(method: "scheduler.list", params: [:])

        switch listResult {
        case .ok(let payload):
            guard let dict = payload as? [String: Any] else {
                XCTFail("Expected dictionary payload")
                return
            }
            XCTAssertEqual(dict["count"] as? Int, 1)
            let tasks = dict["tasks"] as? [[String: Any]]
            XCTAssertEqual(tasks?.count, 1)
            XCTAssertEqual(tasks?[0]["name"] as? String, "roundtrip-task")
            XCTAssertEqual(tasks?[0]["id"] as? String, createdTaskId)

            // Full response must be valid JSON (for --json output)
            XCTAssertTrue(JSONSerialization.isValidJSONObject(dict))
        case .err(let code, let msg, _):
            XCTFail("Expected .ok but got .err(\(code): \(msg))")
        }
    }

    // MARK: - Logs response is valid JSON

    func testSchedulerLogsResponseIsValidJSON() {
        let taskId = UUID()
        let run = TaskRun(
            taskId: taskId,
            startedAt: Date().addingTimeInterval(-60),
            completedAt: Date(),
            exitCode: 0,
            status: .succeeded
        )
        SchedulerEngine.shared.runs = [run]

        let result = TerminalController.shared.v2SchedulerDispatch(
            method: "scheduler.logs",
            params: ["task_id": taskId.uuidString]
        )

        switch result {
        case .ok(let payload):
            guard let dict = payload as? [String: Any] else {
                XCTFail("Expected dictionary payload")
                return
            }
            XCTAssertTrue(JSONSerialization.isValidJSONObject(dict))
            XCTAssertEqual(dict["count"] as? Int, 1)
            let runs = dict["runs"] as? [[String: Any]]
            XCTAssertEqual(runs?.count, 1)
            XCTAssertEqual(runs?[0]["status"] as? String, "succeeded")
        case .err(let code, let msg, _):
            XCTFail("Expected .ok but got .err(\(code): \(msg))")
        }
    }
}
