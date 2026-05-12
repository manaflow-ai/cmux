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


final class SidebarWorkspaceResourceResolverTests: XCTestCase {
    func testResolveAggregatesTTYAgentAndBrowserProcessTreesPerWorkspace() throws {
        let workspaceA = UUID()
        let workspaceB = UUID()

        let processes: [Int32: SidebarWorkspaceTrackedProcessSample] = [
            10: sample(pid: 10, parentPID: 1, name: "zsh", ttyDevice: 100, residentBytes: 200, totalCPUTimeNanos: 100_000_000),
            20: sample(pid: 20, parentPID: 10, name: "claude", ttyDevice: 100, residentBytes: 500, totalCPUTimeNanos: 400_000_000),
            21: sample(pid: 21, parentPID: 20, name: "clangd", ttyDevice: nil, residentBytes: 300, totalCPUTimeNanos: 300_000_000),
            22: sample(pid: 22, parentPID: 20, name: "node", ttyDevice: nil, residentBytes: 250, totalCPUTimeNanos: 100_000_000),
            30: sample(pid: 30, parentPID: 999, name: "WebContent", ttyDevice: nil, residentBytes: 450, totalCPUTimeNanos: 200_000_000),
            31: sample(pid: 31, parentPID: 30, name: "GPUProcess", ttyDevice: nil, residentBytes: 150, totalCPUTimeNanos: 50_000_000),
            40: sample(pid: 40, parentPID: 1, name: "zsh", ttyDevice: 200, residentBytes: 100, totalCPUTimeNanos: 20_000_000),
            41: sample(pid: 41, parentPID: 40, name: "codex", ttyDevice: 200, residentBytes: 600, totalCPUTimeNanos: 250_000_000),
            999: sample(pid: 999, parentPID: 1, name: "cmux", ttyDevice: nil, residentBytes: 800, totalCPUTimeNanos: 150_000_000),
        ]
        let previousCPUTimeByPID = Dictionary(uniqueKeysWithValues: processes.keys.map { ($0, UInt64(0)) })

        let result = SidebarWorkspaceResourceResolver.resolve(
            workspaces: [
                workspaceA: SidebarWorkspaceResourceTrackingRoots(
                    ttyDevices: [100],
                    agentRoots: [.init(key: "claude_code", pid: 20)],
                    browserRootPIDs: [30]
                ),
                workspaceB: SidebarWorkspaceResourceTrackingRoots(
                    ttyDevices: [200],
                    agentRoots: [.init(key: "codex", pid: 41)],
                    browserRootPIDs: []
                ),
            ],
            processes: processes,
            appPID: 999,
            previousCPUTimeByPID: previousCPUTimeByPID,
            elapsedNanoseconds: 1_000_000_000
        )
        let workspaceAUsage = try XCTUnwrap(result.workspaces[workspaceA])
        let workspaceBUsage = try XCTUnwrap(result.workspaces[workspaceB])
        let totalUsage = try XCTUnwrap(result.total)

        XCTAssertEqual(workspaceAUsage.residentBytes, 1_850)
        XCTAssertEqual(workspaceBUsage.residentBytes, 700)
        XCTAssertEqual(totalUsage.residentBytes, 3_350)

        XCTAssertEqual(workspaceAUsage.cpuPercent, 115, accuracy: 0.001)
        XCTAssertEqual(workspaceBUsage.cpuPercent, 27, accuracy: 0.001)
        XCTAssertEqual(totalUsage.cpuPercent, 157, accuracy: 0.001)

        let workspaceAKinds = Dictionary(
            uniqueKeysWithValues: workspaceAUsage.processes.map { ($0.pid, $0.kind) }
        )
        XCTAssertEqual(workspaceAKinds[10], .shell)
        XCTAssertEqual(workspaceAKinds[20], .agent)
        XCTAssertEqual(workspaceAKinds[21], .languageServer)
        XCTAssertEqual(workspaceAKinds[22], .helper)
        XCTAssertEqual(workspaceAKinds[30], .browser)
        XCTAssertEqual(workspaceAKinds[31], .helper)
    }

    func testResolveUsesPreviousCPUTimeTotalsToComputeDeltaPercentages() throws {
        let workspace = UUID()
        let result = SidebarWorkspaceResourceResolver.resolve(
            workspaces: [
                workspace: SidebarWorkspaceResourceTrackingRoots(
                    ttyDevices: [300],
                    agentRoots: [],
                    browserRootPIDs: []
                ),
            ],
            processes: [
                50: sample(
                    pid: 50,
                    parentPID: 1,
                    name: "zsh",
                    ttyDevice: 300,
                    residentBytes: 256,
                    totalCPUTimeNanos: 1_500_000_000
                ),
            ],
            appPID: 999,
            previousCPUTimeByPID: [50: 1_000_000_000],
            elapsedNanoseconds: 2_000_000_000
        )

        let usage = try XCTUnwrap(result.workspaces[workspace])
        XCTAssertEqual(usage.cpuPercent, 25, accuracy: 0.001)
    }

    func testResolveDoesNotChargeNewlyTrackedProcessLifetimeCPUToFirstSample() throws {
        let workspace = UUID()
        let result = SidebarWorkspaceResourceResolver.resolve(
            workspaces: [
                workspace: SidebarWorkspaceResourceTrackingRoots(
                    ttyDevices: [300],
                    agentRoots: [],
                    browserRootPIDs: []
                ),
            ],
            processes: [
                50: sample(
                    pid: 50,
                    parentPID: 1,
                    name: "zsh",
                    ttyDevice: 300,
                    residentBytes: 256,
                    totalCPUTimeNanos: 1_500_000_000
                ),
                51: sample(
                    pid: 51,
                    parentPID: 50,
                    name: "node",
                    ttyDevice: nil,
                    residentBytes: 512,
                    totalCPUTimeNanos: 20_000_000_000
                ),
            ],
            appPID: 999,
            previousCPUTimeByPID: [50: 1_000_000_000],
            elapsedNanoseconds: 2_000_000_000
        )

        let usage = try XCTUnwrap(result.workspaces[workspace])
        XCTAssertEqual(usage.cpuPercent, 25, accuracy: 0.001)

        let child = try XCTUnwrap(usage.processes.first { $0.pid == 51 })
        XCTAssertEqual(child.cpuPercent, 0, accuracy: 0.001)
    }

    func testResolveReportsZeroCPUUntilPreviousBaselineExists() throws {
        let workspace = UUID()
        let result = SidebarWorkspaceResourceResolver.resolve(
            workspaces: [
                workspace: SidebarWorkspaceResourceTrackingRoots(
                    ttyDevices: [300],
                    agentRoots: [],
                    browserRootPIDs: []
                ),
            ],
            processes: [
                50: sample(
                    pid: 50,
                    parentPID: 1,
                    name: "zsh",
                    ttyDevice: 300,
                    residentBytes: 256,
                    totalCPUTimeNanos: 1_500_000_000
                ),
            ],
            appPID: 999,
            previousCPUTimeByPID: [:],
            elapsedNanoseconds: 2_000_000_000
        )

        let usage = try XCTUnwrap(result.workspaces[workspace])
        XCTAssertEqual(usage.cpuPercent, 0, accuracy: 0.001)
    }

    private func sample(
        pid: Int32,
        parentPID: Int32,
        name: String,
        ttyDevice: UInt32?,
        residentBytes: UInt64,
        totalCPUTimeNanos: UInt64
    ) -> SidebarWorkspaceTrackedProcessSample {
        SidebarWorkspaceTrackedProcessSample(
            pid: pid,
            parentPID: parentPID,
            name: name,
            ttyDevice: ttyDevice,
            residentBytes: residentBytes,
            totalCPUTimeNanos: totalCPUTimeNanos
        )
    }
}
