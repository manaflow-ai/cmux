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

    func testNonzeroChildExitIsRepresentedAsFailure() {
        let now = Date(timeIntervalSince1970: 1)
        var operation = AgentFanOutOperation(
            id: "f_test", machineID: "vm", scope: "scope", remoteWorkspaceID: "ws",
            agent: "codex", argvDigest: "digest", requestedCount: 1,
            createdAt: now, updatedAt: now, state: .running,
            children: [AgentFanOutChild(index: 0, terminalID: "term_1", state: .failed, exitCode: 2, errorCode: "agent_exit_nonzero", startedAt: now, endedAt: now)]
        )
        operation.recomputeState(now: now)
        XCTAssertEqual(operation.state, .failed)
        XCTAssertEqual(operation.children[0].errorCode, "agent_exit_nonzero")
    }

    func testFoundationObjectDoesNotExposeArgvOrPrompt() {
        let operation = operation()
        XCTAssertNil(operation.foundationObject["argv"])
        XCTAssertNil(operation.foundationObject["prompt"])
        XCTAssertEqual(operation.foundationObject["operation_id"] as? String, "f_test")
    }

    func testFoundationObjectCarriesPerChildWorkspaceProjectionIdentity() {
        let now = Date(timeIntervalSince1970: 1)
        let child = AgentFanOutChild(
            index: 0,
            remoteWorkspaceID: "ws_child",
            localWorkspaceID: "local-child",
            terminalID: "term_child",
            state: .running,
            exitCode: nil,
            errorCode: nil,
            startedAt: now,
            endedAt: nil
        )
        var value = operation()
        value.children = [child]
        let object = value.foundationObject
        XCTAssertEqual(object["remote_workspace_ids"] as? [String], ["ws_child"])
        guard let children = object["children"] as? [[String: Any]], let first = children.first else {
            return XCTFail("child receipt is missing")
        }
        XCTAssertEqual(first["remote_workspace_id"] as? String, "ws_child")
        XCTAssertEqual(first["local_workspace_id"] as? String, "local-child")
    }

    func testNonZeroChildExitIsPartialFailure() {
        let now = Date(timeIntervalSince1970: 1)
        var operation = AgentFanOutOperation(
            id: "f_test", machineID: "vm", scope: "scope", remoteWorkspaceID: "ws",
            agent: "codex", argvDigest: "digest", requestedCount: 2,
            createdAt: now, updatedAt: now, state: .running,
            children: [
                AgentFanOutChild(index: 0, terminalID: "term_1", state: .exited, exitCode: 0, errorCode: nil, startedAt: now, endedAt: now),
                AgentFanOutChild(index: 1, terminalID: "term_2", state: .failed, exitCode: 2, errorCode: "agent_exit_nonzero", startedAt: now, endedAt: now),
            ]
        )
        operation.recomputeState(now: now)
        XCTAssertEqual(operation.state, .partial)
        XCTAssertEqual(operation.settledCount, 2)
    }

    func testOperationStoreMergesStaleUpdatesWithoutLosingTerminalReceipt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-fan-out-merge-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("operations.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AgentFanOutOperationStore(fileURL: file)
        try await store.insertIfAbsent(operation())
        var exited = operation()
        exited.children[0].state = .exited
        exited.children[0].exitCode = 0
        exited.recomputeState(now: Date(timeIntervalSince1970: 2))
        try await store.update(exited)

        var stale = operation()
        stale.children[0].terminalID = nil
        stale.children[0].state = .running
        try await store.update(stale)
        let current = try await store.operation(id: "f_test")
        XCTAssertEqual(current?.children.first?.state, .exited)
        XCTAssertEqual(current?.children.first?.terminalID, "term_1")
        XCTAssertEqual(current?.children.first?.exitCode, 0)
    }

    func testOperationStoreRejectsCorruptLedgerInsteadOfTreatingItAsEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-fan-out-corrupt-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("operations.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: file)

        let store = AgentFanOutOperationStore(fileURL: file)
        do {
            _ = try await store.operation(id: "f_test")
            XCTFail("corrupt operation ledger must fail closed")
        } catch {
            // Expected: callers must not retry work against an unreadable ledger.
        }
    }

    func testOperationStorePersistsAcrossFreshInstancesAndReservesID() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-fan-out-tests-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("operations.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = AgentFanOutOperationStore(fileURL: file)
        let inserted = try await first.insertIfAbsent(operation())
        XCTAssertTrue(inserted)
        let duplicate = try await first.insertIfAbsent(operation())
        XCTAssertFalse(duplicate)

        // A new actor models an app restart: it must load the same stable
        // account/team scoped record from disk.
        let afterRestart = AgentFanOutOperationStore(fileURL: file)
        let restoredValue = try await afterRestart.operation(id: "f_test")
        let restored = try XCTUnwrap(restoredValue)
        XCTAssertEqual(restored.scope, "account:team")
        XCTAssertEqual(restored.remoteWorkspaceID, "ws")
        XCTAssertEqual(restored.children.first?.terminalID, "term_1")
    }
}
