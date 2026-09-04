import Darwin
@_implementationOnly import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exercises the process-group lifecycle with a real shell and descendant.
final class AutomationProcessSessionTests: XCTestCase {
    func testProcessSessionCleansUpDescendants() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-automation-process-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pidURL = directory.appendingPathComponent("child.pid")
        let command = "sleep 5 & printf '%s' $! > '\(pidURL.path)'; exit 0"
        let session = AutomationProcessSession(command: command, environment: [:])

        _ = await session.run()
        let clock = ContinuousClock()
        var childPID: pid_t?
        for _ in 0..<50 {
            if let raw = try? String(contentsOf: pidURL, encoding: .utf8),
               let parsed = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                childPID = parsed
                break
            }
            try await clock.sleep(for: .milliseconds(20))
        }
        let pid = try XCTUnwrap(childPID)
        for _ in 0..<50 {
            if Self.processHasExited(pid) { break }
            try await clock.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(Self.processHasExited(pid))
    }

    private static func processHasExited(_ pid: pid_t) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size > 0,
              info.kp_proc.p_pid == pid else {
            return true
        }
        return Int32(info.kp_proc.p_stat) == SZOMB
    }
}
