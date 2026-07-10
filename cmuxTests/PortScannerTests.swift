import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class ProcessTerminationGateTests: XCTestCase {
    func testPrelaunchTerminationRequestIsDeferredUntilLaunch() {
        let gate = ProcessTerminationGate()

        XCTAssertFalse(
            gate.requestTermination(),
            "A cancellation that arrives before Process.run() succeeds must not touch the Process."
        )
        XCTAssertTrue(
            gate.markLaunched(),
            "Once launch succeeds, the deferred termination request should be applied to the running Process."
        )
        gate.markFinished()
        XCTAssertFalse(
            gate.requestTermination(),
            "Late cancellation after completion must not touch Process termination state."
        )
    }

    func testFinishedPrelaunchProcessIgnoresDeferredTermination() {
        let gate = ProcessTerminationGate()

        XCTAssertFalse(gate.requestTermination())
        gate.markFinished()
        XCTAssertFalse(
            gate.markLaunched(),
            "If launch fails and the run is already finished, no deferred termination should be applied."
        )
    }
}
