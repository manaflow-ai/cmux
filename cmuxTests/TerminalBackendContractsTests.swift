import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class TerminalBackendContractsTests: XCTestCase {
    func testBackendIdentityRoundTripsThroughJSON() throws {
        let identity = TerminalWorkspaceBackendIdentity(
            teamID: "team_123",
            taskID: "task_456",
            taskRunID: "task_run_789",
            workspaceName: "Mac mini",
            descriptor: "cmux@cmux-macmini"
        )

        let data = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(TerminalWorkspaceBackendIdentity.self, from: data)

        XCTAssertEqual(decoded, identity)
    }

    func testBackendMetadataRoundTripsThroughJSON() throws {
        let metadata = TerminalWorkspaceBackendMetadata(preview: "feature/direct-daemon")

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(TerminalWorkspaceBackendMetadata.self, from: data)

        XCTAssertEqual(decoded, metadata)
    }

    func testDaemonInitialWriteGateKeepsWritesQueuedUntilFirstOutput() {
        var gate = DaemonInitialWriteGate(enabled: true)
        var pendingWrites = [Data("cmux welcome\n".utf8)]

        let assigned = gate.takeWritesForAssignedSession(&pendingWrites)
        XCTAssertTrue(assigned.writes.isEmpty)
        XCTAssertEqual(assigned.queuedCount, 1)
        XCTAssertEqual(pendingWrites, [Data("cmux welcome\n".utf8)])
        XCTAssertTrue(gate.shouldQueueWrites)

        let emptyOutput = gate.takeWritesAfterOutput(&pendingWrites, outputIsEmpty: true)
        XCTAssertTrue(emptyOutput.writes.isEmpty)
        XCTAssertFalse(emptyOutput.becameReady)
        XCTAssertEqual(pendingWrites, [Data("cmux welcome\n".utf8)])

        let firstOutput = gate.takeWritesAfterOutput(&pendingWrites, outputIsEmpty: false)
        XCTAssertEqual(firstOutput.writes, [Data("cmux welcome\n".utf8)])
        XCTAssertTrue(firstOutput.becameReady)
        XCTAssertTrue(pendingWrites.isEmpty)
        XCTAssertFalse(gate.shouldQueueWrites)
    }

    func testDaemonInitialWriteGateFlushesImmediatelyWhenDisabled() {
        var gate = DaemonInitialWriteGate(enabled: false)
        var pendingWrites = [Data("pwd\n".utf8)]

        let assigned = gate.takeWritesForAssignedSession(&pendingWrites)

        XCTAssertEqual(assigned.writes, [Data("pwd\n".utf8)])
        XCTAssertEqual(assigned.queuedCount, 0)
        XCTAssertTrue(pendingWrites.isEmpty)
        XCTAssertFalse(gate.shouldQueueWrites)
    }
}
