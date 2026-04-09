// cmuxTests/IslandSessionPhaseTests.swift

import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class IslandSessionPhaseTests: XCTestCase {

    func testRunningSynonyms() {
        let inputs = ["running", "Running", "RUNNING",
                      "running_tool", "processing", "starting", " running "]
        for input in inputs {
            XCTAssertEqual(
                IslandSessionPhase.from(rawValue: input), .running,
                "Expected .running for \(input)"
            )
        }
    }

    func testIdleSynonyms() {
        let inputs = ["idle", "Idle", "IDLE", "", "  ", "ready"]
        for input in inputs {
            XCTAssertEqual(
                IslandSessionPhase.from(rawValue: input), .idle,
                "Expected .idle for \(input)"
            )
        }
    }

    func testWaitingSynonyms() {
        let inputs = ["waiting", "waiting_for_input", "needs_input", "needsinput", "NeedsInput"]
        for input in inputs {
            XCTAssertEqual(
                IslandSessionPhase.from(rawValue: input), .waiting,
                "Expected .waiting for \(input)"
            )
        }
    }

    func testErrorSynonyms() {
        let inputs = ["error", "Error", "failed", "Failure"]
        for input in inputs {
            XCTAssertEqual(
                IslandSessionPhase.from(rawValue: input), .error,
                "Expected .error for \(input)"
            )
        }
    }

    func testUnknownFallsThrough() {
        for input in ["compacting", "queued", "💤", "hello world"] {
            XCTAssertEqual(
                IslandSessionPhase.from(rawValue: input), .unknown,
                "Expected .unknown for \(input)"
            )
        }
    }
}
