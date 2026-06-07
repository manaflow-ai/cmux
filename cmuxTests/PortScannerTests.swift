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

    private func fdInspectionUnavailableError(
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Error {
        let environment = ProcessInfo.processInfo.environment
        if environment["CI"] == "true" || environment["GITHUB_ACTIONS"] == "true" {
            XCTFail("\(message); hosted CI must exercise PortScanner pipe FD leak coverage", file: file, line: line)
            return NSError(domain: "cmux.tests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
        return XCTSkip(message)
    }

    func testCaptureStandardOutputDoesNotLeakPipeFDs() throws {
        guard let baseline = openFDCount() else {
            throw fdInspectionUnavailableError("Unable to inspect /dev/fd on this runner")
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
            throw fdInspectionUnavailableError("Unable to inspect final /dev/fd count on this runner")
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
