import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class ScheduledTaskModelTests: XCTestCase {

    // MARK: - ScheduledTask Codable

    func testScheduledTaskCodableRoundTrip() throws {
        let task = ScheduledTask(
            name: "nightly backup",
            cronExpression: "0 3 * * *",
            command: "/usr/local/bin/backup.sh",
            workingDirectory: "/home/user",
            environment: ["BACKUP_MODE": "full"],
            isEnabled: true,
            allowOverlap: false,
            useWorktree: true,
            onSuccess: "echo done",
            onFailure: "echo failed",
            createdAt: Date(timeIntervalSince1970: 1700000000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(task)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScheduledTask.self, from: data)

        XCTAssertEqual(task.id, decoded.id)
        XCTAssertEqual(task.name, decoded.name)
        XCTAssertEqual(task.cronExpression, decoded.cronExpression)
        XCTAssertEqual(task.command, decoded.command)
        XCTAssertEqual(task.workingDirectory, decoded.workingDirectory)
        XCTAssertEqual(task.environment, decoded.environment)
        XCTAssertEqual(task.isEnabled, decoded.isEnabled)
        XCTAssertEqual(task.allowOverlap, decoded.allowOverlap)
        XCTAssertEqual(task.useWorktree, decoded.useWorktree)
        XCTAssertEqual(task.onSuccess, decoded.onSuccess)
        XCTAssertEqual(task.onFailure, decoded.onFailure)
        XCTAssertEqual(task.createdAt, decoded.createdAt)
        XCTAssertEqual(task, decoded)
    }

    func testScheduledTaskCodableWithNilOptionals() throws {
        let task = ScheduledTask(
            name: "simple",
            cronExpression: "*/5 * * * *",
            command: "echo hello",
            createdAt: Date(timeIntervalSince1970: 1700000000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(task)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScheduledTask.self, from: data)

        XCTAssertEqual(task.id, decoded.id)
        XCTAssertEqual(task.name, decoded.name)
        XCTAssertNil(decoded.workingDirectory)
        XCTAssertNil(decoded.environment)
        XCTAssertNil(decoded.useWorktree)
        XCTAssertNil(decoded.onSuccess)
        XCTAssertNil(decoded.onFailure)
        XCTAssertEqual(task, decoded)
    }

    func testScheduledTaskDefaultValues() {
        let task = ScheduledTask(
            name: "test",
            cronExpression: "* * * * *",
            command: "echo"
        )

        XCTAssertTrue(task.isEnabled)
        XCTAssertFalse(task.allowOverlap)
        XCTAssertNil(task.useWorktree)
        XCTAssertNil(task.workingDirectory)
        XCTAssertNil(task.environment)
        XCTAssertNil(task.onSuccess)
        XCTAssertNil(task.onFailure)
    }

    // MARK: - TaskRun Codable

    func testTaskRunCodableRoundTrip() throws {
        let taskId = UUID()
        let panelId = UUID()
        let run = TaskRun(
            taskId: taskId,
            panelId: panelId,
            startedAt: Date(timeIntervalSince1970: 1700000000),
            completedAt: Date(timeIntervalSince1970: 1700000060),
            exitCode: 0,
            status: .succeeded
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(run)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TaskRun.self, from: data)

        XCTAssertEqual(run.id, decoded.id)
        XCTAssertEqual(run.taskId, decoded.taskId)
        XCTAssertEqual(run.panelId, decoded.panelId)
        XCTAssertEqual(run.startedAt, decoded.startedAt)
        XCTAssertEqual(run.completedAt, decoded.completedAt)
        XCTAssertEqual(run.exitCode, decoded.exitCode)
        XCTAssertEqual(run.status, decoded.status)
        XCTAssertEqual(run, decoded)
    }

    func testTaskRunCodableRunningState() throws {
        let run = TaskRun(
            taskId: UUID(),
            startedAt: Date(timeIntervalSince1970: 1700000000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(run)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TaskRun.self, from: data)

        XCTAssertEqual(run.id, decoded.id)
        XCTAssertEqual(decoded.status, .running)
        XCTAssertNil(decoded.completedAt)
        XCTAssertNil(decoded.exitCode)
        XCTAssertNil(decoded.panelId)
        XCTAssertEqual(run, decoded)
    }

    func testTaskRunDefaultStatus() {
        let run = TaskRun(taskId: UUID())
        XCTAssertEqual(run.status, .running)
        XCTAssertNil(run.completedAt)
        XCTAssertNil(run.exitCode)
        XCTAssertNil(run.panelId)
    }

    // MARK: - TaskRunStatus Codable

    func testTaskRunStatusCodableAllCases() throws {
        let allCases: [TaskRunStatus] = [.running, .succeeded, .failed, .cancelled]
        let expectedStrings = ["running", "succeeded", "failed", "cancelled"]

        for (status, expected) in zip(allCases, expectedStrings) {
            let data = try JSONEncoder().encode(status)
            let jsonString = String(data: data, encoding: .utf8)!
            XCTAssertEqual(jsonString, "\"\(expected)\"", "Status \(status) should serialize to \"\(expected)\"")

            let decoded = try JSONDecoder().decode(TaskRunStatus.self, from: data)
            XCTAssertEqual(decoded, status, "Status \(expected) should round-trip correctly")
        }
    }

    func testTaskRunStatusRawValues() {
        XCTAssertEqual(TaskRunStatus.running.rawValue, "running")
        XCTAssertEqual(TaskRunStatus.succeeded.rawValue, "succeeded")
        XCTAssertEqual(TaskRunStatus.failed.rawValue, "failed")
        XCTAssertEqual(TaskRunStatus.cancelled.rawValue, "cancelled")
    }

    func testTaskRunStatusFromInvalidString() {
        let invalid = TaskRunStatus(rawValue: "unknown")
        XCTAssertNil(invalid, "Invalid raw value should return nil")
    }

    // MARK: - JSON array round-trip (persistence scenario)

    func testScheduledTaskArrayCodableRoundTrip() throws {
        let tasks = [
            ScheduledTask(name: "task1", cronExpression: "0 * * * *", command: "echo 1", createdAt: Date(timeIntervalSince1970: 1700000000)),
            ScheduledTask(name: "task2", cronExpression: "*/10 * * * *", command: "echo 2", isEnabled: false, createdAt: Date(timeIntervalSince1970: 1700000060)),
        ]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(tasks)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([ScheduledTask].self, from: data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].name, "task1")
        XCTAssertEqual(decoded[1].name, "task2")
        XCTAssertTrue(decoded[0].isEnabled)
        XCTAssertFalse(decoded[1].isEnabled)
        XCTAssertEqual(tasks, decoded)
    }
}
