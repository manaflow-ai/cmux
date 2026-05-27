import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class PortScannerProcessCaptureTests: XCTestCase {
    private func openFDCount() -> Int? {
        try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }

    func testCaptureStandardOutputDoesNotLeakPipeFDs() throws {
        guard let baseline = openFDCount() else {
            throw XCTSkip("Unable to inspect /dev/fd on this runner")
        }

        var maxCount = baseline
        for _ in 0..<200 {
            let output = PortScanner.captureStandardOutput(
                executablePath: "/usr/bin/printf",
                arguments: ["cmux"]
            )
            XCTAssertEqual(output, "cmux")
            if let current = openFDCount() {
                maxCount = max(maxCount, current)
            }
        }

        guard let finalCount = openFDCount() else {
            throw XCTSkip("Unable to inspect final /dev/fd count on this runner")
        }

        XCTAssertLessThanOrEqual(maxCount - baseline, 8)
        XCTAssertLessThanOrEqual(finalCount - baseline, 8)
    }
}

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
