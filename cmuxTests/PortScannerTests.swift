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

final class SessionIndexRipgrepCancellationTests: XCTestCase {
    func testRipgrepCancellationBeforeLaunchDoesNotAbort() async throws {
        try XCTSkipUnless(
            RipgrepExecutableResolver.resolve(configuredPath: nil) != nil,
            "ripgrep is required for session search cancellation behavior"
        )

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "needle\n".write(
            to: rootURL.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let task = Task { () -> [URL]? in
            await Task.yield()
            return await SessionIndexStore.ripgrepMatchingPaths(
                needle: "needle",
                root: rootURL.path,
                fileGlob: "*.jsonl"
            )
        }
        task.cancel()

        _ = await task.value
    }
}
