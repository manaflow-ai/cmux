import XCTest

final class AgentFanOutOperationTests: XCTestCase {
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
        let now = Date(timeIntervalSince1970: 1)
        let operation = AgentFanOutOperation(
            id: "f_test", machineID: "vm", scope: "scope", remoteWorkspaceID: "ws",
            agent: "codex", argvDigest: "digest", requestedCount: 1,
            createdAt: now, updatedAt: now, state: .running,
            children: [AgentFanOutChild(index: 0, terminalID: "term_1", state: .running, exitCode: nil, errorCode: nil, startedAt: now, endedAt: nil)]
        )
        XCTAssertNil(operation.foundationObject["argv"])
        XCTAssertNil(operation.foundationObject["prompt"])
        XCTAssertEqual(operation.foundationObject["operation_id"] as? String, "f_test")
    }
}
