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

    func testCPUPercentagesHoldPreviousValueUntilFixedWindowElapses() {
        let key = CmuxTopProcessScopeCacheKey(
            pid: 4_129_001,
            startSeconds: 1_000,
            startMicroseconds: 0
        )
        let activeKeys: Set<CmuxTopProcessScopeCacheKey> = [key]

        _ = CmuxTopProcessSnapshot.cpuPercentages(
            for: [
                key: CmuxTopProcessCPUSample(
                    totalTimeTicks: 1_000,
                    sampledAtNanoseconds: 1_000_000_000
                )
            ],
            activeKeys: activeKeys,
            sampledAtNanoseconds: 1_000_000_000
        )

        let rapidPercentages = CmuxTopProcessSnapshot.cpuPercentages(
            for: [
                key: CmuxTopProcessCPUSample(
                    totalTimeTicks: 1_000_001_000,
                    sampledAtNanoseconds: 1_100_000_000
                )
            ],
            activeKeys: activeKeys,
            sampledAtNanoseconds: 1_100_000_000
        )

        XCTAssertEqual(rapidPercentages[key], 0)

        let fixedWindowPercentages = CmuxTopProcessSnapshot.cpuPercentages(
            for: [
                key: CmuxTopProcessCPUSample(
                    totalTimeTicks: 1_000_002_000,
                    sampledAtNanoseconds: 2_000_000_000
                )
            ],
            activeKeys: activeKeys,
            sampledAtNanoseconds: 2_000_000_000
        )

        XCTAssertGreaterThan(fixedWindowPercentages[key] ?? 0, 0)
    }

    func testExitedChildCPUPercentCarriesIntoActiveParentForOneSample() {
        let parentKey = CmuxTopProcessScopeCacheKey(
            pid: 4_129_100,
            startSeconds: 1_000,
            startMicroseconds: 0
        )
        let childKey = CmuxTopProcessScopeCacheKey(
            pid: 4_129_101,
            startSeconds: 1_000,
            startMicroseconds: 1
        )
        let activeParentAndChild: Set<CmuxTopProcessScopeCacheKey> = [parentKey, childKey]

        _ = CmuxTopProcessSnapshot.cpuPercentages(
            for: [
                parentKey: CmuxTopProcessCPUSample(totalTimeTicks: 1_000, sampledAtNanoseconds: 10_000_000_000),
                childKey: CmuxTopProcessCPUSample(totalTimeTicks: 1_000, sampledAtNanoseconds: 10_000_000_000),
            ],
            activeKeys: activeParentAndChild,
            parentKeysByKey: [childKey: parentKey],
            sampledAtNanoseconds: 10_000_000_000
        )
        let activePercentages = CmuxTopProcessSnapshot.cpuPercentages(
            for: [
                parentKey: CmuxTopProcessCPUSample(totalTimeTicks: 1_000, sampledAtNanoseconds: 11_000_000_000),
                childKey: CmuxTopProcessCPUSample(totalTimeTicks: 1_000_001_000, sampledAtNanoseconds: 11_000_000_000),
            ],
            activeKeys: activeParentAndChild,
            parentKeysByKey: [childKey: parentKey],
            sampledAtNanoseconds: 11_000_000_000
        )

        XCTAssertGreaterThan(activePercentages[childKey] ?? 0, 0)

        let parentOnlyPercentages = CmuxTopProcessSnapshot.cpuPercentages(
            for: [
                parentKey: CmuxTopProcessCPUSample(totalTimeTicks: 1_000, sampledAtNanoseconds: 12_000_000_000),
            ],
            activeKeys: [parentKey],
            sampledAtNanoseconds: 12_000_000_000
        )

        XCTAssertGreaterThan(parentOnlyPercentages[parentKey] ?? 0, 0)
        XCTAssertNil(parentOnlyPercentages[childKey])
    }

    func testExitedChildCPUPercentDoesNotInflateHeldParentSample() {
        let parentKey = CmuxTopProcessScopeCacheKey(
            pid: 4_129_200,
            startSeconds: 1_000,
            startMicroseconds: 0
        )
        let childKey = CmuxTopProcessScopeCacheKey(
            pid: 4_129_201,
            startSeconds: 1_000,
            startMicroseconds: 1
        )
        let activeParentAndChild: Set<CmuxTopProcessScopeCacheKey> = [parentKey, childKey]

        _ = CmuxTopProcessSnapshot.cpuPercentages(
            for: [
                parentKey: CmuxTopProcessCPUSample(totalTimeTicks: 1_000, sampledAtNanoseconds: 20_000_000_000),
                childKey: CmuxTopProcessCPUSample(totalTimeTicks: 1_000, sampledAtNanoseconds: 20_000_000_000),
            ],
            activeKeys: activeParentAndChild,
            parentKeysByKey: [childKey: parentKey],
            sampledAtNanoseconds: 20_000_000_000
        )
        let activePercentages = CmuxTopProcessSnapshot.cpuPercentages(
            for: [
                parentKey: CmuxTopProcessCPUSample(totalTimeTicks: 1_000, sampledAtNanoseconds: 21_000_000_000),
                childKey: CmuxTopProcessCPUSample(totalTimeTicks: 1_000_001_000, sampledAtNanoseconds: 21_000_000_000),
            ],
            activeKeys: activeParentAndChild,
            parentKeysByKey: [childKey: parentKey],
            sampledAtNanoseconds: 21_000_000_000
        )

        XCTAssertEqual(activePercentages[parentKey], 0)
        XCTAssertGreaterThan(activePercentages[childKey] ?? 0, 0)

        let heldParentOnlyPercentages = CmuxTopProcessSnapshot.cpuPercentages(
            for: [
                parentKey: CmuxTopProcessCPUSample(totalTimeTicks: 1_000, sampledAtNanoseconds: 21_100_000_000),
            ],
            activeKeys: [parentKey],
            sampledAtNanoseconds: 21_100_000_000
        )

        XCTAssertEqual(heldParentOnlyPercentages[parentKey], 0)
        XCTAssertNil(heldParentOnlyPercentages[childKey])
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
