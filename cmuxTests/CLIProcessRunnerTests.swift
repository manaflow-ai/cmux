import XCTest

#if canImport(cmux)
@testable import cmux

final class CLIProcessRunnerTests: XCTestCase {
    func testRunProcessTimesOutHungChild() {
        let startedAt = Date()
        let result = CLIProcessRunner.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", "sleep 5"],
            timeout: 0.2
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.status, 124)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2.0)
    }
}
#endif
