import XCTest

final class AgentFanOutOperationTests: XCTestCase {
    private func operation(id: String = "f_test") -> AgentFanOutOperation {
        let now = Date(timeIntervalSince1970: 1)
        return AgentFanOutOperation(
            id: id, machineID: "vm", scope: "account:team", remoteWorkspaceID: "ws",
            agent: "codex", argvDigest: "digest", requestedCount: 1,
            createdAt: now, updatedAt: now, state: .running,
            children: [AgentFanOutChild(index: 0, terminalID: "term_1", state: .running, exitCode: nil, errorCode: nil, startedAt: now, endedAt: nil)]
        )
    }

    func testValidationRejectsInvalidCountsAndAgent() {
        XCTAssertEqual(
            AgentFanOutOperation.validate(machineID: "vm", agent: "codex", argv: ["codex", "exec"], count: 0),
            "count must be between 1 and 32"
        )
        XCTAssertEqual(
            AgentFanOutOperation.validate(machineID: "vm", agent: "unknown", argv: ["agent"], count: 2),
            "unsupported agent 'unknown'"
        )
        XCTAssertNil(AgentFanOutOperation.validate(machineID: "vm", agent: "codex", argv: ["codex", "exec"], count: 2))
    }

    func testDigestIsStableAndChangesWithArgv() {
        let first = AgentFanOutOperation.digest(argv: ["codex", "exec", "review"])
        XCTAssertEqual(first, AgentFanOutOperation.digest(argv: ["codex", "exec", "review"]))
        XCTAssertNotEqual(first, AgentFanOutOperation.digest(argv: ["codex", "exec", "fix"]))
    }

    func testAggregateStateBecomesPartialWhenOneChildFails() {
        let now = Date(timeIntervalSince1970: 1)
        var operation = AgentFanOutOperation(
            id: "f_test", machineID: "vm", scope: "scope", remoteWorkspaceID: "ws",
            agent: "codex", argvDigest: "digest", requestedCount: 2,
            createdAt: now, updatedAt: now, state: .creating,
            children: [
                AgentFanOutChild(index: 0, terminalID: "term_1", state: .running, exitCode: nil, errorCode: nil, startedAt: now, endedAt: nil),
                AgentFanOutChild(index: 1, terminalID: nil, state: .failed, exitCode: nil, errorCode: "quota", startedAt: nil, endedAt: now),
            ]
        )
        operation.recomputeState(now: now)
        XCTAssertEqual(operation.state, .partial)
        XCTAssertEqual(operation.createdCount, 1)
        XCTAssertEqual(operation.settledCount, 1)
    }

    func testFoundationObjectDoesNotExposeArgvOrPrompt() {
        let operation = operation()
        XCTAssertNil(operation.foundationObject["argv"])
        XCTAssertNil(operation.foundationObject["prompt"])
        XCTAssertEqual(operation.foundationObject["operation_id"] as? String, "f_test")
    }

    func testOperationStorePersistsAcrossFreshInstancesAndReservesID() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-fan-out-tests-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("operations.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = AgentFanOutOperationStore(fileURL: file)
        let inserted = await first.insertIfAbsent(operation())
        XCTAssertTrue(inserted)
        let duplicate = await first.insertIfAbsent(operation())
        XCTAssertFalse(duplicate)

        // A new actor models an app restart: it must load the same stable
        // account/team scoped record from disk.
        let afterRestart = AgentFanOutOperationStore(fileURL: file)
        let restoredValue = await afterRestart.operation(id: "f_test")
        let restored = try XCTUnwrap(restoredValue)
        XCTAssertEqual(restored.scope, "account:team")
        XCTAssertEqual(restored.remoteWorkspaceID, "ws")
        XCTAssertEqual(restored.children.first?.terminalID, "term_1")
    }
}
