import XCTest

final class AgentFanOutOperationTests: XCTestCase {
    private func operation(id: String = "f_test") -> AgentFanOutOperation {
        let now = Date(timeIntervalSince1970: 1)
        return AgentFanOutOperation(
            id: id, machineID: "vm", scope: "account:team", remoteWorkspaceID: "ws",
            agent: "codex", argvDigest: "digest", requestedCount: 1,
            createdAt: now, updatedAt: now, state: .running,
            children: [AgentFanOutChild(index: 0, creationCorrelationKey: "cmux-agent-fan-out-correlation-0", terminalID: "term_1", state: .running, exitCode: nil, errorCode: nil, startedAt: now, endedAt: nil)]
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

    func testOperationStorePreservesStartingCorrelationReceiptAcrossStaleRetry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-fan-out-correlation-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("operations.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AgentFanOutOperationStore(fileURL: file)
        var reserved = operation(id: "f_recover")
        reserved.children[0].terminalID = nil
        reserved.children[0].state = .starting
        reserved.children[0].remoteWorkspaceID = "ws_recover"
        try await store.insertIfAbsent(reserved)

        // A stale creator snapshot may omit the receipt fields. It must not
        // erase the workspace or correlation key needed for daemon recovery.
        var stale = reserved
        stale.children[0].remoteWorkspaceID = nil
        stale.children[0].creationCorrelationKey = nil
        try await store.update(stale)
        let recoveredValue = try await store.operation(id: "f_recover")
        let recovered = try XCTUnwrap(recoveredValue)
        XCTAssertEqual(recovered.children[0].remoteWorkspaceID, "ws_recover")
        XCTAssertEqual(recovered.children[0].creationCorrelationKey, "cmux-agent-fan-out-correlation-0")

        let reloadedValue = try await AgentFanOutOperationStore(fileURL: file).operation(id: "f_recover")
        let reloaded = try XCTUnwrap(reloadedValue)
        XCTAssertEqual(reloaded.children[0].remoteWorkspaceID, "ws_recover")
        XCTAssertEqual(reloaded.children[0].creationCorrelationKey, "cmux-agent-fan-out-correlation-0")
    }

    func testExplicitSharedWorkspaceCanRepairAnInterruptedChildReceipt() {
        var value = operation(id: "f_shared_recovery")
        value.children[0].state = .starting
        value.children[0].terminalID = nil
        value.children[0].remoteWorkspaceID = nil
        value.remoteWorkspaceID = ""
        value.adoptExplicitWorkspaceForRecovery(" ws_shared ")
        XCTAssertEqual(value.remoteWorkspaceID, "ws_shared")
        XCTAssertEqual(value.children[0].remoteWorkspaceID, "ws_shared")
        XCTAssertEqual(value.children[0].creationCorrelationKey, "cmux-agent-fan-out-correlation-0")
    }

    func testDefaultFanOutDoesNotGuessAWorkspaceDuringRecovery() {
        var value = operation(id: "f_default_recovery")
        value.children[0].state = .starting
        value.children[0].terminalID = nil
        value.children[0].remoteWorkspaceID = nil
        value.remoteWorkspaceID = ""
        value.adoptExplicitWorkspaceForRecovery("")
        XCTAssertNil(value.children[0].remoteWorkspaceID)
        XCTAssertEqual(value.remoteWorkspaceID, "")
    }

    func testRecoveryFailsClosedWhenAChildReceiptIsMissing() {
        var value = operation(id: "f_missing_receipt")
        value.children[0].state = .starting
        value.children[0].terminalID = nil
        value.children[0].remoteWorkspaceID = nil
        value.prepareForRecovery(now: Date(timeIntervalSince1970: 4))
        XCTAssertEqual(value.children[0].state, .failed)
        XCTAssertEqual(value.children[0].errorCode, "workspace_receipt_unavailable")
        XCTAssertEqual(value.children[0].endedAt, Date(timeIntervalSince1970: 4))
        XCTAssertEqual(value.state, .failed)
    }

    func testOperationStoreSerializesCreationRecoveryClaims() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-fan-out-claims-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("operations.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentFanOutOperationStore(fileURL: file)
        try await store.insertIfAbsent(operation(id: "f_claim"))
        let firstClaim = try await store.beginCreation(id: "f_claim")
        XCTAssertTrue(firstClaim)
        let duplicateClaim = try await store.beginCreation(id: "f_claim")
        XCTAssertFalse(duplicateClaim)
        await store.endCreation(id: "f_claim")
        let laterClaim = try await store.beginCreation(id: "f_claim")
        XCTAssertTrue(laterClaim)
    }


    func testOperationStoreMergesLateLocalProjectionAfterExit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-fan-out-late-projection-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("operations.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentFanOutOperationStore(fileURL: file)
        for exitCode in [0, 2] {
            for projectionSucceeds in [true, false] {
                let id = "f_\(exitCode)_\(projectionSucceeds)"
                let creator = operation(id: id)
                try await store.insertIfAbsent(creator)

                var settled = creator
                settled.children[0].state = exitCode == 0 ? .exited : .failed
                settled.children[0].exitCode = exitCode
                settled.children[0].errorCode = exitCode == 0 ? nil : "agent_exit_nonzero"
                settled.children[0].endedAt = Date(timeIntervalSince1970: 2)
                settled.recomputeState(now: Date(timeIntervalSince1970: 2))
                try await store.update(settled)

                // The creator still holds its running snapshot while the
                // status worker has already settled the remote terminal.
                var projected = creator
                projected.children[0].localWorkspaceID = projectionSucceeds ? "local-child" : nil
                projected.children[0].projectionErrorCode = projectionSucceeds ? nil : "local_projection_failed"
                try await store.update(projected)
                let stored = try await store.operation(id: id)
                let current = try XCTUnwrap(stored)
                XCTAssertEqual(current.children[0].state, settled.children[0].state)
                XCTAssertEqual(current.children[0].exitCode, exitCode)
                XCTAssertEqual(current.children[0].endedAt, settled.children[0].endedAt)
                XCTAssertEqual(current.children[0].errorCode, settled.children[0].errorCode)
                XCTAssertEqual(current.children[0].localWorkspaceID, projected.children[0].localWorkspaceID)
                XCTAssertEqual(current.children[0].projectionErrorCode, projected.children[0].projectionErrorCode)

                // A second stale status snapshot must preserve the newly
                // persisted local projection receipt and its failure code.
                _ = try await store.mergeTerminalExits(creator)
                let staleMerged = try await store.operation(id: id)
                XCTAssertEqual(staleMerged?.children, current.children)
                let reloaded = try await AgentFanOutOperationStore(fileURL: file).operation(id: id)
                XCTAssertEqual(reloaded?.children, current.children)
            }
        }
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
