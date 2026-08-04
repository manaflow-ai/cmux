import CmuxCore
import CmuxFoundation
import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Port scanner process capture", .serialized)
struct PortScannerProcessCaptureTests {
    @Test("lsof avoids blocking kernel calls and suppresses warnings")
    func lsofUsesNonblockingFlags() async {
        let defaults = UserDefaults.standard
        let showPortsKey = SidebarWorkspaceDetailDefaults.showPortsKey
        let previousShowPorts = defaults.object(forKey: showPortsKey)
        defaults.set(true, forKey: showPortsKey)
        defer {
            if let previousShowPorts {
                defaults.set(previousShowPorts, forKey: showPortsKey)
            } else {
                defaults.removeObject(forKey: showPortsKey)
            }
        }
        let runner = StubCommandRunner(result: CommandResult(
            stdout: "",
            stderr: "",
            exitStatus: 1,
            timedOut: false,
            executionError: nil
        ))

        _ = await PortScanner(commandRunner: runner).runLsof(pidsCsv: "123,456")

        #expect(await runner.recordedInvocations() == [
            StubCommandInvocation(
                directory: "/",
                executable: "/usr/sbin/lsof",
                arguments: [
                    "-nP", "-b", "-w", "-a", "-p", "123,456",
                    "-iTCP", "-sTCP:LISTEN", "-Fpn",
                ],
                timeout: PortScanner.processScanTimeout
            ),
        ])
    }

    @Test("Hidden sidebar ports execute no scan subprocesses")
    func hiddenSidebarPortsSkipScanSubprocesses() async {
        let defaults = UserDefaults.standard
        let showPortsKey = SidebarWorkspaceDetailDefaults.showPortsKey
        let previousShowPorts = defaults.object(forKey: showPortsKey)
        defaults.set(false, forKey: showPortsKey)
        defer {
            if let previousShowPorts {
                defaults.set(previousShowPorts, forKey: showPortsKey)
            } else {
                defaults.removeObject(forKey: showPortsKey)
            }
        }
        let runner = StubCommandRunner(result: CommandResult(
            stdout: "",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))
        let scanner = PortScanner(commandRunner: runner)

        _ = await scanner.runPS(ttyList: "ttys001")
        _ = await scanner.runAllProcesses()
        _ = await scanner.runLsof(pidsCsv: "123")

        #expect(await runner.recordedInvocations().isEmpty)
    }

    @Test("Rapid port visibility transitions preserve the final enabled state")
    func rapidPortVisibilityTransitionsRestoreScanning() async {
        let enabled = OSAllocatedUnfairLock(initialState: true)
        let runner = StubCommandRunner(result: CommandResult(
            stdout: "",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))
        let scanner = PortScanner(
            commandRunner: runner,
            portScanningEnabledProvider: { enabled.withLock { $0 } }
        )
        let releaseQueue = DispatchSemaphore(value: 0)
        scanner.queue.async {
            releaseQueue.wait()
        }

        await MainActor.run {
            scanner.registerTTY(
                workspaceId: UUID(),
                panelId: UUID(),
                ttyName: "ttys001"
            )
        }
        enabled.withLock { $0 = false }
        scanner.portScanningSettingsDidChange()
        enabled.withLock { $0 = true }
        scanner.portScanningSettingsDidChange()
        releaseQueue.signal()

        let deadline = ContinuousClock.now + .seconds(2)
        while await runner.recordedInvocations().isEmpty,
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(await runner.recordedInvocations().contains {
            $0.executable == "/bin/ps"
        })
    }

    @Test("Malformed ps rows preserve valid mappings but make the scan incomplete")
    func malformedPSRowsAreIncomplete() async {
        let runner = StubCommandRunner(result: CommandResult(
            stdout: "123 ttys001\nmalformed\n456 ttys002 extra\n",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))
        let scan = await PortScanner(commandRunner: runner).runPS(ttyList: "ttys001,ttys002")

        #expect(scan.values == [123: "ttys001"])
        #expect(scan.completeness == .incomplete)
    }

    @Test("Malformed lsof rows are incomplete only for their owning PID")
    func malformedLsofRowsArePIDScoped() async {
        let runner = StubCommandRunner(result: CommandResult(
            stdout: "p123\nf3\nn*:4200\nnmalformed\np456\nf3\nn*:4300\n",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))
        let scan = await PortScanner(
            commandRunner: runner,
            processIdentityProvider: {
                AgentPIDProcessIdentity(pid: $0, startSeconds: 1, startMicroseconds: 0)
            }
        ).runLsof(pidsCsv: "123,456")

        #expect(scan.values == [123: [4200], 456: [4300]])
        #expect(scan.completeness(for: [123]) == .incomplete)
        #expect(scan.completeness(for: [456]) == .complete)
    }

    @Test("A clean lsof field stream is complete")
    func cleanLsofRowsAreComplete() async {
        let runner = StubCommandRunner(result: CommandResult(
            stdout: "p123\nf3\nn*:4200\n",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))
        let scan = await PortScanner(
            commandRunner: runner,
            processIdentityProvider: {
                AgentPIDProcessIdentity(pid: $0, startSeconds: 1, startMicroseconds: 0)
            }
        ).runLsof(pidsCsv: "123")

        #expect(scan.values == [123: [4200]])
        #expect(scan.completeness == .complete)
    }

    @Test("lsof diagnostics preserve valid ports but make the scan incomplete")
    func lsofDiagnosticsAreIncomplete() async {
        let runner = StubCommandRunner(result: CommandResult(
            stdout: "p123\nf3\nn*:4200\n",
            stderr: "lsof: permission denied\n",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))
        let scan = await PortScanner(commandRunner: runner).runLsof(pidsCsv: "123")

        #expect(scan.values == [123: [4200]])
        #expect(scan.completeness == .incomplete)
    }

    @Test("A confirmed absent PID is safe negative lsof evidence")
    func absentPIDIsCompleteNegativeEvidence() async {
        let runner = StubCommandRunner(result: CommandResult(
            stdout: "p100\nf3\nn*:4200\n",
            stderr: "",
            exitStatus: 1,
            timedOut: false,
            executionError: nil
        ))
        let liveIdentity = AgentPIDProcessIdentity(
            pid: 100,
            startSeconds: 1,
            startMicroseconds: 0
        )
        let scan = await PortScanner(
            commandRunner: runner,
            processIdentityProvider: { $0 == liveIdentity.pid ? liveIdentity : nil },
            processPresenceProvider: { $0 == liveIdentity.pid ? .present : .absent }
        ).runLsof(pidsCsv: "100,200")

        #expect(scan.values == [100: [4200]])
        #expect(scan.completeness(for: [100]) == .complete)
        #expect(scan.completeness(for: [200]) == .complete)
    }

    @Test("Panel lsof completeness is scoped to PIDs on that panel's TTY")
    func panelLsofCompletenessIsTTYScoped() {
        let workspaceID = UUID()
        let healthyPanel = PortScanner.PanelKey(workspaceId: workspaceID, panelId: UUID())
        let failedPanel = PortScanner.PanelKey(workspaceId: workspaceID, panelId: UUID())
        let lsofScan = PortLsofScanResult(
            values: [100: [4200]],
            globallyComplete: true,
            incompletePIDs: [200]
        )

        let completeness = PortScanner.panelCompletenessByKey(
            panelTTYs: [healthyPanel: "ttys001", failedPanel: "ttys002"],
            pidToTTY: [100: "ttys001", 200: "ttys002"],
            psCompleteness: .complete,
            lsofScan: lsofScan
        )

        #expect(completeness[healthyPanel] == .complete)
        #expect(completeness[failedPanel] == .incomplete)
    }

    @Test("A panel with no PIDs needs only an authoritative process scan")
    func noPIDPanelCompletenessUsesProcessScan() {
        let panel = PortScanner.PanelKey(workspaceId: UUID(), panelId: UUID())

        let complete = PortScanner.panelCompletenessByKey(
            panelTTYs: [panel: "ttys001"],
            pidToTTY: [:],
            psCompleteness: .complete,
            lsofScan: nil
        )
        let incomplete = PortScanner.panelCompletenessByKey(
            panelTTYs: [panel: "ttys001"],
            pidToTTY: [:],
            psCompleteness: .incomplete,
            lsofScan: nil
        )

        #expect(complete[panel] == .complete)
        #expect(incomplete[panel] == .incomplete)
    }

    @Test("Process scan timeout is bounded and incomplete")
    func processScanTimeoutIsIncomplete() async {
        let runner = StubCommandRunner(result: CommandResult(
            stdout: nil,
            stderr: nil,
            exitStatus: nil,
            timedOut: true,
            executionError: nil
        ))
        let scan = await PortScanner(commandRunner: runner).runPS(ttyList: "ttys001")
        let timeout = await runner.lastTimeout

        #expect(scan.values.isEmpty)
        #expect(scan.completeness == .incomplete)
        #expect(timeout == PortScanner.processScanTimeout)
    }
}

@Suite("Agent process identity validation")
struct AgentProcessIdentityValidationTests {
    @Test("Nested roots visit and own each descendant once per workspace")
    func nestedRootsHaveBoundedWorkspaceOwnership() async {
        let workspaceID = UUID()
        let firstIdentity = AgentPIDProcessIdentity(pid: 100, startSeconds: 10, startMicroseconds: 0)
        let secondIdentity = AgentPIDProcessIdentity(pid: 101, startSeconds: 20, startMicroseconds: 0)
        let firstRoot = AgentPortRootIdentity(pid: 100, processIdentity: firstIdentity)
        let secondRoot = AgentPortRootIdentity(pid: 101, processIdentity: secondIdentity)
        let runner = StubCommandRunner(result: CommandResult(
            stdout: "100 1\n101 100\n102 101\n103 102\n",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))
        let scanner = PortScanner(
            commandRunner: runner,
            processIdentityProvider: { pid in
                switch pid {
                case firstIdentity.pid: firstIdentity
                case secondIdentity.pid: secondIdentity
                default: nil
                }
            }
        )

        let scan = await scanner.expandAgentProcessTree(
            agentRootsByWorkspace: [workspaceID: [firstRoot, secondRoot]]
        )

        #expect(scan.values == [100: [workspaceID], 101: [workspaceID], 102: [workspaceID], 103: [workspaceID]])
        #expect(scan.completenessByWorkspace[workspaceID] == .complete)
    }

    @Test("A matching birth identity is retained for process-tree expansion")
    func matchingIdentityIsAccepted() {
        let workspaceID = UUID()
        let identity = AgentPIDProcessIdentity(
            pid: 100,
            startSeconds: 10,
            startMicroseconds: 20
        )
        let root = AgentPortRootIdentity(pid: 100, processIdentity: identity)
        let scanner = PortScanner(processIdentityProvider: { pid in
            pid == identity.pid ? identity : nil
        })

        let validation = scanner.validateAgentRoots([workspaceID: [root]])

        #expect(validation.values == [workspaceID: [root]])
        #expect(validation.completenessByWorkspace[workspaceID] == .complete)
    }

    @Test("Roots recycled or unavailable after process capture retain no descendants")
    func postCaptureInvalidRootsAreRejectedBeforeTraversal() async {
        let workspaceID = UUID()
        let recorded = AgentPIDProcessIdentity(pid: 100, startSeconds: 10, startMicroseconds: 20)
        let recycled = AgentPIDProcessIdentity(pid: 100, startSeconds: 11, startMicroseconds: 0)
        let root = AgentPortRootIdentity(pid: 100, processIdentity: recorded)
        for postCaptureIdentity in [recycled, nil] as [AgentPIDProcessIdentity?] {
            // Serializes the async runner's identity flip with synchronous provider reads.
            let identity = OSAllocatedUnfairLock(initialState: Optional(recorded))
            let runner = StubCommandRunner(
                result: CommandResult(
                    stdout: "100 1\n101 100\n",
                    stderr: "",
                    exitStatus: 0,
                    timedOut: false,
                    executionError: nil
                ),
                onRun: { identity.withLock { $0 = postCaptureIdentity } }
            )
            let scanner = PortScanner(
                commandRunner: runner,
                processIdentityProvider: { _ in identity.withLock { $0 } },
                processPresenceProvider: { _ in .present }
            )

            let scan = await scanner.expandAgentProcessTree(agentRootsByWorkspace: [workspaceID: [root]])

            #expect(scan.values.isEmpty)
            #expect(scan.completenessByWorkspace[workspaceID] == (postCaptureIdentity == nil ? .incomplete : .complete))
        }
    }

    @Test("An initially unavailable root skips the process scan with incomplete evidence")
    func initiallyUnavailableRootSkipsProcessScan() async {
        let workspaceID = UUID()
        let identity = AgentPIDProcessIdentity(pid: 100, startSeconds: 10, startMicroseconds: 20)
        let root = AgentPortRootIdentity(pid: 100, processIdentity: identity)
        // Serializes the async runner callback with the synchronous assertion read.
        let didRun = OSAllocatedUnfairLock(initialState: false)
        let runner = StubCommandRunner(
            result: CommandResult(
                stdout: "100 1\n",
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            ),
            onRun: { didRun.withLock { $0 = true } }
        )
        let scanner = PortScanner(
            commandRunner: runner,
            processIdentityProvider: { _ in nil },
            processPresenceProvider: { _ in .present }
        )

        let scan = await scanner.expandAgentProcessTree(agentRootsByWorkspace: [workspaceID: [root]])

        #expect(scan.values.isEmpty)
        #expect(scan.completenessByWorkspace[workspaceID] == .incomplete)
        #expect(didRun.withLock { $0 } == false)
    }

    @Test("One unavailable root does not widen incompleteness to another workspace")
    func rootCompletenessIsWorkspaceScoped() {
        let healthyWorkspaceID = UUID()
        let unavailableWorkspaceID = UUID()
        let healthyIdentity = AgentPIDProcessIdentity(pid: 100, startSeconds: 10, startMicroseconds: 0)
        let unavailableIdentity = AgentPIDProcessIdentity(pid: 200, startSeconds: 20, startMicroseconds: 0)
        let healthyRoot = AgentPortRootIdentity(pid: 100, processIdentity: healthyIdentity)
        let unavailableRoot = AgentPortRootIdentity(pid: 200, processIdentity: unavailableIdentity)
        let scanner = PortScanner(
            processIdentityProvider: { pid in
                pid == healthyIdentity.pid ? healthyIdentity : nil
            },
            processPresenceProvider: { _ in .present }
        )

        let validation = scanner.validateAgentRoots([
            healthyWorkspaceID: [healthyRoot],
            unavailableWorkspaceID: [unavailableRoot]
        ])

        #expect(validation.completenessByWorkspace[healthyWorkspaceID] == .complete)
        #expect(validation.completenessByWorkspace[unavailableWorkspaceID] == .incomplete)
    }

    @Test("lsof incompleteness is scoped to workspaces that own the failed PID")
    func lsofCompletenessIsPIDScoped() {
        let scan = PortLsofScanResult(
            values: [100: [4200]],
            globallyComplete: true,
            incompletePIDs: [200]
        )

        #expect(scan.completeness(for: [100]) == .complete)
        #expect(scan.completeness(for: [200]) == .incomplete)
        #expect(scan.completeness(for: [100, 200]) == .incomplete)
    }
}

@Suite("Port scan coordination")
struct PortScanCoordinationTests {
    @Test("Panel scans stay single-flight and coalesce one pending pass")
    func panelScansAreBoundedAndCoalesced() {
        var coordination = PortScanCoordination()

        let firstScan = coordination.beginPanelScan()
        #expect(firstScan)
        let firstPendingScan = coordination.beginPanelScan()
        #expect(firstPendingScan == false)
        let coalescedPendingScan = coordination.beginPanelScan()
        #expect(coalescedPendingScan == false)
        let shouldRunPendingScan = coordination.finishPanelScan()
        #expect(shouldRunPendingScan)
        let pendingScan = coordination.beginPanelScan()
        #expect(pendingScan)
        let isFinished = coordination.finishPanelScan()
        #expect(isFinished == false)
    }

    @Test("Agent scans merge pending workspace inputs behind one in-flight pass")
    func agentScansAreBoundedAndMerged() throws {
        var coordination = PortScanCoordination()
        let firstWorkspace = UUID()
        let secondWorkspace = UUID()
        let first = AgentPortScanRequest(
            workspaceIds: [firstWorkspace],
            rootInput: AgentPortScanRootInput(
                rootsByWorkspace: [firstWorkspace: [AgentPortRootIdentity(pid: 100, processIdentity: nil)]]
            ),
            agentRevisions: [firstWorkspace: 1],
            requestID: coordination.makeRequestID()
        )
        let newer = AgentPortScanRequest(
            workspaceIds: [firstWorkspace, secondWorkspace],
            rootInput: AgentPortScanRootInput(rootsByWorkspace: [
                firstWorkspace: [AgentPortRootIdentity(pid: 101, processIdentity: nil)],
                secondWorkspace: [AgentPortRootIdentity(pid: 200, processIdentity: nil)]
            ]),
            agentRevisions: [firstWorkspace: 2, secondWorkspace: 1],
            requestID: coordination.makeRequestID()
        )
        let latest = AgentPortScanRequest(
            workspaceIds: [secondWorkspace],
            rootInput: AgentPortScanRootInput(
                rootsByWorkspace: [secondWorkspace: [AgentPortRootIdentity(pid: 201, processIdentity: nil)]]
            ),
            agentRevisions: [secondWorkspace: 2],
            requestID: coordination.makeRequestID()
        )

        let firstScan = coordination.enqueueAgentScan(first)
        #expect(firstScan == first)
        let coalescedScan = coordination.enqueueAgentScan(newer)
        #expect(coalescedScan == nil)
        let mergedScan = coordination.enqueueAgentScan(latest)
        #expect(mergedScan == nil)
        let finishedScan = coordination.finishAgentScan()
        let pending = try #require(finishedScan)
        let pendingRoots = pending.rootInput.rootsByWorkspace
        #expect(pending.workspaceIds == [firstWorkspace, secondWorkspace])
        #expect(pendingRoots[firstWorkspace]?.map(\.pid) == [101])
        #expect(pendingRoots[secondWorkspace]?.map(\.pid) == [201])
        #expect(pending.agentRevisions == [firstWorkspace: 2, secondWorkspace: 2])
        #expect(pending.requestID == latest.requestID)

        let nextScan = coordination.enqueueAgentScan(first)
        #expect(nextScan == nil)
        let nextPending = coordination.finishAgentScan()
        #expect(nextPending?.requestID == first.requestID)
    }

    @Test("Older asynchronous results are rejected after a newer result applies")
    func staleResultsAreRejected() {
        var coordination = PortScanCoordination()
        let workspaceID = UUID()
        let older = coordination.makeRequestID()
        let newer = coordination.makeRequestID()

        let newerPanelResult = coordination.shouldApplyPanelResult(requestID: newer)
        #expect(newerPanelResult)
        let olderPanelResult = coordination.shouldApplyPanelResult(requestID: older)
        #expect(olderPanelResult == false)
        let newerAgentWorkspaces = coordination.newAgentWorkspaces(
            [workspaceID],
            eligibleWorkspaceIds: [workspaceID],
            requestID: newer
        )
        #expect(newerAgentWorkspaces == [workspaceID])
        let olderAgentWorkspaces = coordination.newAgentWorkspaces(
            [workspaceID],
            eligibleWorkspaceIds: [workspaceID],
            requestID: older
        )
        #expect(olderAgentWorkspaces.isEmpty)
        #expect(coordination.isLatestAgentResult(workspaceId: workspaceID, requestID: newer))
    }

    @Test("Agent ordering only retains eligible lifecycle workspaces")
    func agentOrderingOnlyRetainsEligibleWorkspaces() {
        var coordination = PortScanCoordination()
        let panelOnlyWorkspaceID = UUID()
        let forcedClearWorkspaceID = UUID()
        let requestID = coordination.makeRequestID()

        let agentWorkspaces = coordination.newAgentWorkspaces(
            [panelOnlyWorkspaceID, forcedClearWorkspaceID],
            eligibleWorkspaceIds: [forcedClearWorkspaceID],
            requestID: requestID
        )

        #expect(agentWorkspaces == [forcedClearWorkspaceID])
        #expect(coordination.isLatestAgentResult(workspaceId: panelOnlyWorkspaceID, requestID: requestID) == false)
        #expect(coordination.isLatestAgentResult(workspaceId: forcedClearWorkspaceID, requestID: requestID))

        coordination.removeAgentWorkspaces([forcedClearWorkspaceID])

        #expect(coordination.isLatestAgentResult(workspaceId: forcedClearWorkspaceID, requestID: requestID) == false)
    }

}

@Suite("Process termination gate")
struct ProcessTerminationGateTests {
    @Test("A prelaunch termination request is deferred until launch")
    func prelaunchTerminationRequestIsDeferredUntilLaunch() {
        var gate = ProcessTerminationGate()

        let shouldTerminateBeforeLaunch = gate.requestTermination()
        #expect(shouldTerminateBeforeLaunch == false)
        let shouldTerminateAfterLaunch = gate.markLaunched()
        #expect(shouldTerminateAfterLaunch)
        gate.markFinished()
        let shouldTerminateAfterFinish = gate.requestTermination()
        #expect(shouldTerminateAfterFinish == false)
    }

    @Test("A finished prelaunch process ignores deferred termination")
    func finishedPrelaunchProcessIgnoresDeferredTermination() {
        var gate = ProcessTerminationGate()

        let shouldTerminateBeforeLaunch = gate.requestTermination()
        #expect(shouldTerminateBeforeLaunch == false)
        gate.markFinished()
        let shouldTerminateAfterFinish = gate.markLaunched()
        #expect(shouldTerminateAfterFinish == false)
    }
}

private struct StubCommandInvocation: Equatable, Sendable {
    let directory: String
    let executable: String
    let arguments: [String]
    let timeout: TimeInterval?
}

private actor StubCommandRunner: CommandRunning {
    let result: CommandResult
    let onRun: (@Sendable () -> Void)?
    private(set) var lastTimeout: TimeInterval?
    private var invocations: [StubCommandInvocation] = []

    init(result: CommandResult, onRun: (@Sendable () -> Void)? = nil) {
        self.result = result
        self.onRun = onRun
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        lastTimeout = timeout
        invocations.append(StubCommandInvocation(
            directory: directory,
            executable: executable,
            arguments: arguments,
            timeout: timeout
        ))
        onRun?()
        return result
    }

    func recordedInvocations() -> [StubCommandInvocation] {
        invocations
    }
}
