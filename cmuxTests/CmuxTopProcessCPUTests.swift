import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CmuxTopProcessCPUTests: XCTestCase {
    func testOverflowSentinelReportsZeroCPUPercent() {
        let previous = CmuxTopProcessCPUSample(
            totalTimeTicks: 100,
            sampledAtNanoseconds: 1_000
        )
        let current = CmuxTopProcessCPUSample(
            totalTimeTicks: UInt64.max,
            sampledAtNanoseconds: 2_000
        )

        XCTAssertEqual(CmuxTopProcessSnapshot.cpuPercent(current: current, previous: previous), 0)
    }

    func testBusyChildProcessReportsNonZeroCPUPercent() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while :; do :; done"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        defer { terminate(process) }

        let pid = Int(process.processIdentifier)
        _ = CmuxTopProcessSnapshot.capture(includeProcessDetails: false).summary(for: [pid])

        let observedCPU = waitForCPUPercent(pid: pid, timeout: 5)

        XCTAssertGreaterThan(observedCPU, 0.1)
    }

    private func waitForCPUPercent(pid: Int, timeout: TimeInterval) -> Double {
        let deadline = Date.now.addingTimeInterval(timeout)
        var maxCPU = 0.0

        while Date.now < deadline {
            let cpu = CmuxTopProcessSnapshot.capture(includeProcessDetails: false)
                .summary(for: [pid])
                .cpuPercent
            maxCPU = max(maxCPU, cpu)
            if cpu > 0.1 {
                return cpu
            }

            _ = RunLoop.current.run(mode: .default, before: Date.now.addingTimeInterval(0.2))
        }

        return maxCPU
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()

        let deadline = Date.now.addingTimeInterval(2)
        while process.isRunning, Date.now < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date.now.addingTimeInterval(0.05))
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }
}
