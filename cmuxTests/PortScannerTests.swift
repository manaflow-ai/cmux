@testable import CmuxComputerUse
import CmuxCore
import CmuxFoundation
import Darwin
import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Port scanner owner-scoped completeness")
struct PortScannerOwnerScopedCompletenessTests {
    @Test("An unrelated incomplete PID does not pin a known listener port")
    func unrelatedIncompletePIDDoesNotPinListener() {
        let workspaceID = UUID()
        let listener = AgentPIDProcessIdentity(pid: 101, startSeconds: 10, startMicroseconds: 0)
        let unrelated = AgentPIDProcessIdentity(pid: 102, startSeconds: 11, startMicroseconds: 0)
        let scanner = PortScanner(
            processIdentityProvider: { pid in
                pid == listener.pid ? listener : nil
            },
            processPresenceProvider: { _ in .present }
        )
        let lsofScan = PortListenerScanResult(
            values: [:],
            globallyComplete: true,
            incompletePIDs: [Int(unrelated.pid)]
        )

        let completeness = scanner.missingPortCompletenessByKey(
            previousOwnersByKey: [workspaceID: [4200: [listener]]],
            observedOwnersByKey: [:],
            currentProcessIdentitiesByKey: [workspaceID: [listener]],
            processScopeCompletenessByKey: [workspaceID: .incomplete],
            scannedKeys: [workspaceID],
            lsofScan: lsofScan,
            inspectedPIDs: [Int(listener.pid)]
        )

        #expect(completeness[workspaceID]?[4200] == .complete)
    }

    @Test("An unreadable live owner keeps its missing port incomplete")
    func unreadableLiveOwnerRemainsIncomplete() {
        let workspaceID = UUID()
        let listener = AgentPIDProcessIdentity(pid: 101, startSeconds: 10, startMicroseconds: 0)
        let scanner = PortScanner(
            processIdentityProvider: { _ in nil },
            processPresenceProvider: { _ in .present }
        )
        let lsofScan = PortListenerScanResult(
            values: [:],
            globallyComplete: true,
            incompletePIDs: []
        )

        let completeness = scanner.missingPortCompletenessByKey(
            previousOwnersByKey: [workspaceID: [4200: [listener]]],
            observedOwnersByKey: [:],
            currentProcessIdentitiesByKey: [:],
            processScopeCompletenessByKey: [workspaceID: .incomplete],
            scannedKeys: [workspaceID],
            lsofScan: lsofScan,
            inspectedPIDs: [Int(listener.pid)]
        )

        #expect(completeness[workspaceID]?[4200] == .incomplete)
    }
}

@Suite("Port scanner ownership-scope evidence")
struct PortScannerOwnershipScopeEvidenceTests {
    @Test("A live owner dropped by an incomplete graph does not retire its port")
    func incompleteOwnershipGraphRetainsLiveOwnerPort() {
        let workspaceID = UUID()
        let listener = AgentPIDProcessIdentity(pid: 101, startSeconds: 10, startMicroseconds: 0)
        let scanner = PortScanner(
            processIdentityProvider: { _ in listener },
            processPresenceProvider: { _ in .present }
        )
        let lsofScan = PortListenerScanResult(
            values: [Int(listener.pid): [4200]],
            globallyComplete: true,
            incompletePIDs: []
        )

        let completeness = scanner.missingPortCompletenessByKey(
            previousOwnersByKey: [workspaceID: [4200: [listener]]],
            observedOwnersByKey: [:],
            currentProcessIdentitiesByKey: [:],
            processScopeCompletenessByKey: [workspaceID: .incomplete],
            scannedKeys: [workspaceID],
            lsofScan: lsofScan,
            inspectedPIDs: [Int(listener.pid)]
        )

        #expect(completeness[workspaceID]?[4200] == .incomplete)
    }

    @Test("A live owner absent from a complete graph is authoritative absence")
    func completeOwnershipGraphRetiresDroppedOwnerPort() {
        let workspaceID = UUID()
        let listener = AgentPIDProcessIdentity(pid: 101, startSeconds: 10, startMicroseconds: 0)
        let scanner = PortScanner(
            processIdentityProvider: { _ in listener },
            processPresenceProvider: { _ in .present }
        )
        let lsofScan = PortListenerScanResult(
            values: [Int(listener.pid): [4200]],
            globallyComplete: true,
            incompletePIDs: []
        )

        let completeness = scanner.missingPortCompletenessByKey(
            previousOwnersByKey: [workspaceID: [4200: [listener]]],
            observedOwnersByKey: [:],
            currentProcessIdentitiesByKey: [:],
            processScopeCompletenessByKey: [workspaceID: .complete],
            scannedKeys: [workspaceID],
            lsofScan: lsofScan,
            inspectedPIDs: [Int(listener.pid)]
        )

        #expect(completeness[workspaceID]?[4200] == .complete)
    }

    @Test("Unrelated incomplete lsof evidence does not pin a dropped owner")
    func unrelatedIncompleteLsofDoesNotPinDroppedOwner() {
        let workspaceID = UUID()
        let listener = AgentPIDProcessIdentity(pid: 101, startSeconds: 10, startMicroseconds: 0)
        let scanner = PortScanner(
            processIdentityProvider: { _ in listener },
            processPresenceProvider: { _ in .present }
        )
        let lsofScan = PortListenerScanResult(
            values: [Int(listener.pid): [4200]],
            globallyComplete: false,
            incompletePIDs: [999]
        )

        let completeness = scanner.missingPortCompletenessByKey(
            previousOwnersByKey: [workspaceID: [4200: [listener]]],
            observedOwnersByKey: [:],
            currentProcessIdentitiesByKey: [:],
            processScopeCompletenessByKey: [workspaceID: .complete],
            scannedKeys: [workspaceID],
            lsofScan: lsofScan,
            inspectedPIDs: [Int(listener.pid)]
        )

        #expect(completeness[workspaceID]?[4200] == .complete)
    }
}

@Suite("Port scanner process capture")
struct PortScannerProcessCaptureTests {
    @Test("Ports read from the kernel are complete evidence")
    func kernelPortsAreCompleteEvidence() {
        let scan = PortScanner(
            processIdentityProvider: {
                AgentPIDProcessIdentity(pid: $0, startSeconds: 1, startMicroseconds: 0)
            },
            listeningPortsProvider: { $0 == 123 ? .ports([4200]) : .ports([]) }
        ).scanListeningPorts(pidsCsv: "123")

        #expect(scan.values == [123: [4200]])
        #expect(scan.completeness == .complete)
    }

    @Test("An unreadable live PID is incomplete only for itself")
    func unreadablePIDIsPIDScoped() {
        let scan = PortScanner(
            processIdentityProvider: {
                $0 == 456
                    ? AgentPIDProcessIdentity(pid: $0, startSeconds: 1, startMicroseconds: 0)
                    : nil
            },
            processPresenceProvider: { _ in .present },
            listeningPortsProvider: { $0 == 456 ? .ports([4300]) : .denied }
        ).scanListeningPorts(pidsCsv: "123,456")

        #expect(scan.values == [456: [4300]])
        #expect(scan.completeness(for: [123]) == .incomplete)
        #expect(scan.completeness(for: [456]) == .complete)
    }

    @Test("A root-owned PID we may not read still has a readable identity, so it stays complete")
    func deniedPIDWithReadableIdentityStaysComplete() {
        // The root `login` process heads every terminal's process group. An
        // unprivileged reader never sees its sockets, and treating that as a
        // miss would stop the panel behind it from ever retiring its ports.
        let scan = PortScanner(
            processIdentityProvider: {
                AgentPIDProcessIdentity(pid: $0, startSeconds: 1, startMicroseconds: 0)
            },
            processPresenceProvider: { _ in .present },
            listeningPortsProvider: { _ in .denied }
        ).scanListeningPorts(pidsCsv: "1")

        #expect(scan.values.isEmpty)
        #expect(scan.completeness(for: [1]) == .complete)
    }

    @Test("A confirmed absent PID is safe negative evidence")
    func absentPIDIsCompleteNegativeEvidence() {
        let liveIdentity = AgentPIDProcessIdentity(
            pid: 100,
            startSeconds: 1,
            startMicroseconds: 0
        )
        let scan = PortScanner(
            processIdentityProvider: { $0 == liveIdentity.pid ? liveIdentity : nil },
            processPresenceProvider: { $0 == liveIdentity.pid ? .present : .absent },
            listeningPortsProvider: { $0 == liveIdentity.pid ? .ports([4200]) : .unavailable }
        ).scanListeningPorts(pidsCsv: "100,200")

        #expect(scan.values == [100: [4200]])
        #expect(scan.completeness(for: [100]) == .complete)
        #expect(scan.completeness(for: [200]) == .complete)
    }

    @Test("A process owned by another user still has a readable birth identity")
    func otherUsersProcessHasReadableIdentity() throws {
        // launchd is root-owned on every macOS system, so `proc_pidinfo`
        // refuses it for an unprivileged caller — the same refusal that hides
        // the root `login` process heading every terminal's process group.
        try #require(geteuid() != 0, "the cross-user identity test must run unprivileged")
        var legacyInfo = proc_bsdinfo()
        let expectedLegacySize = MemoryLayout<proc_bsdinfo>.stride
        let legacySize = proc_pidinfo(
            1,
            PROC_PIDTBSDINFO,
            0,
            &legacyInfo,
            Int32(expectedLegacySize)
        )
        #expect(legacySize != expectedLegacySize, "proc_pidinfo unexpectedly read launchd")

        let identity = try #require(AgentPIDProcessIdentity(pid: 1))

        #expect(identity.pid == 1)
        #expect(identity.startSeconds > 0)
        #expect(AgentPIDProcessIdentity(pid: getpid())?.pid == getpid())
        #expect(AgentPIDProcessIdentity(pid: 999_999) == nil)
    }

    @Test("An exited but unreaped process has no readable identity")
    func zombieProcessHasNoReadableIdentity() throws {
        // `sysctl` still describes a zombie, and reports its original birth
        // timestamp, so a caller comparing identities would decide the dead
        // process is the one it recorded and treat the agent as running.
        var pid: pid_t = 0
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { arguments.compactMap { $0 }.forEach { free($0) } }
        try #require(posix_spawn(&pid, "/usr/bin/true", nil, nil, &arguments, environ) == 0)
        defer {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, Self.processStatus(pid: pid) != SZOMB {
            usleep(10_000)
        }

        try #require(Self.processStatus(pid: pid) == SZOMB, "the child never became a zombie")
        #expect(AgentPIDProcessIdentity(pid: pid) == nil)
    }

    @Test("A zombie on a panel's TTY does not withhold negative port evidence")
    func zombieProcessIsAuthoritativeAbsence() async throws {
        // Rejecting zombies as identities is only half the story: a zombie is
        // still signalable, so presence read it as live and the scan filed it
        // as a PID whose ports might have gone unseen. That is the same
        // incompleteness that froze every panel behind the root `login`, and a
        // zombie can hold no socket at all.
        var pid: pid_t = 0
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { arguments.compactMap { $0 }.forEach { free($0) } }
        try #require(posix_spawn(&pid, "/usr/bin/true", nil, nil, &arguments, environ) == 0)
        defer {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, Self.processStatus(pid: pid) != SZOMB {
            usleep(10_000)
        }
        try #require(Self.processStatus(pid: pid) == SZOMB, "the child never became a zombie")

        let panel = PortScanner.PanelKey(workspaceId: UUID(), panelId: UUID())
        let lsofScan = PortScanner().scanListeningPorts(pidsCsv: String(pid))
        let completeness = PortScanner.panelCompletenessByKey(
            panelTTYs: [panel: "ttys001"],
            pidToTTY: [Int(pid): "ttys001"],
            psCompleteness: .complete,
            lsofScan: lsofScan
        )

        #expect(PIDPresence.current(pid: pid) == .absent)
        #expect(lsofScan.completeness(for: [Int(pid)]) == .complete)
        #expect(completeness[panel] == .complete)
    }

    /// The raw `p_stat` the process table reports, or `nil` when the process is
    /// gone entirely.
    private static func processStatus(pid: pid_t) -> Int32? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size > 0,
              info.kp_proc.p_pid == pid else {
            return nil
        }
        return Int32(info.kp_proc.p_stat)
    }

    @Test("A panel hosting a root-owned process can still retire its ports")
    func panelWithRootOwnedProcessStaysComplete() {
        let panel = PortScanner.PanelKey(workspaceId: UUID(), panelId: UUID())
        let rootOwnedPID = 1
        let lsofScan = PortScanner().scanListeningPorts(pidsCsv: String(rootOwnedPID))

        let completeness = PortScanner.panelCompletenessByKey(
            panelTTYs: [panel: "ttys001"],
            pidToTTY: [rootOwnedPID: "ttys001"],
            psCompleteness: .complete,
            lsofScan: lsofScan
        )

        #expect(lsofScan.completeness(for: [rootOwnedPID]) == .complete)
        #expect(completeness[panel] == .complete)
    }

    @Test("Panel lsof completeness is scoped to PIDs on that panel's TTY")
    func panelLsofCompletenessIsTTYScoped() {
        let workspaceID = UUID()
        let healthyPanel = PortScanner.PanelKey(workspaceId: workspaceID, panelId: UUID())
        let failedPanel = PortScanner.PanelKey(workspaceId: workspaceID, panelId: UUID())
        let lsofScan = PortListenerScanResult(
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
        let processTable = StubPortProcessTable(parents: [100: 1, 101: 100, 102: 101, 103: 102])
        let scanner = PortScanner(
            processTable: processTable,
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
            // Serializes the process read's identity flip with synchronous provider reads.
            let identity = OSAllocatedUnfairLock(initialState: Optional(recorded))
            let processTable = StubPortProcessTable(
                parents: [100: 1, 101: 100],
                onRead: { identity.withLock { $0 = postCaptureIdentity } }
            )
            let scanner = PortScanner(
                processTable: processTable,
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
        // Serializes the process read callback with the synchronous assertion read.
        let didRun = OSAllocatedUnfairLock(initialState: false)
        let processTable = StubPortProcessTable(
            parents: [100: 1],
            onRead: { didRun.withLock { $0 = true } }
        )
        let scanner = PortScanner(
            processTable: processTable,
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
        let scan = PortListenerScanResult(
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

/// Records every terminal query a scan makes and answers it as unreadable, so
/// a lifecycle test can observe that a scan ran without publishing evidence.
private actor RecordingPortProcessTable: PortProcessTableReading {
    private(set) var recordedTerminalQueries: [[String]] = []
    private var invocationWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForInvocation() async {
        if !recordedTerminalQueries.isEmpty { return }
        await withCheckedContinuation { continuation in
            invocationWaiters.append(continuation)
        }
    }

    func processesOnTerminals(
        named ttyNames: [String]
    ) async -> (values: [Int: String], completeness: PortScanCompleteness) {
        recordedTerminalQueries.append(ttyNames)
        invocationWaiters.forEach { $0.resume() }
        invocationWaiters.removeAll()
        return ([:], .incomplete)
    }

    func parentsByPID() async -> (values: [Int: Int], completeness: PortScanCompleteness) {
        ([:], .incomplete)
    }
}

@Suite("Port scanner lifecycle")
struct PortScannerLifecycleTests {
    @Test("A stale completion preserves a pending rescan under the current generation")
    func staleCompletionDoesNotConsumePendingRescan() async {
        let processTable = RecordingPortProcessTable()
        let scanner = PortScanner(processTable: processTable)
        let workspaceID = UUID()
        let panelID = UUID()
        await MainActor.run {
            scanner.registerTTY(workspaceId: workspaceID, panelId: panelID, ttyName: "ttys999")
        }

        // Simulate an in-flight scan from generation zero, then invalidate it.
        scanner.queue.sync {
            _ = scanner.scanCoordination.beginPanelScan()
            _ = scanner.scanCoordination.beginPanelScan()
        }
        await MainActor.run {
            scanner.unregisterPanel(workspaceId: workspaceID, panelId: panelID)
        }
        scanner.queue.sync {}
        await MainActor.run {
            scanner.registerTTY(workspaceId: workspaceID, panelId: panelID, ttyName: "ttys999")
        }
        scanner.queue.sync {
            scanner.completePanelScan(
                generation: 0,
                [],
                panelTTYs: [:],
                panelRevisions: [:],
                workspaceIds: [],
                agentPortsByWorkspace: [:],
                panelPortOwnersByKey: [:],
                panelProcessIdentitiesByKey: [:],
                agentPortOwnersByWorkspace: [:],
                agentProcessIdentitiesByWorkspace: [:],
                agentRevisions: [:],
                panelCompletenessByKey: [:],
                panelProcessScopeCompletenessByKey: [:],
                agentCompletenessByWorkspace: [:],
                agentProcessScopeCompletenessByWorkspace: [:],
                panelLsofEvidence: PortListenerScanResult(values: [:], globallyComplete: true, incompletePIDs: []),
                agentLsofEvidence: nil,
                inspectedPIDs: [],
                requestID: 0
            )
        }
        await processTable.waitForInvocation()
        let calls = await processTable.recordedTerminalQueries
        #expect(!calls.isEmpty)
    }

    @Test("Unregister preserves a pending burst for other panels")
    func unregisterPreservesOtherPanelBurst() async {
        let processTable = RecordingPortProcessTable()
        let scanner = PortScanner(processTable: processTable)
        let workspaceID = UUID()
        let removedPanelID = UUID()
        let retainedPanelID = UUID()
        await MainActor.run {
            scanner.registerTTY(workspaceId: workspaceID, panelId: removedPanelID, ttyName: "ttys999")
            scanner.registerTTY(workspaceId: workspaceID, panelId: retainedPanelID, ttyName: "ttys998")
        }
        scanner.kick(workspaceId: workspaceID, panelId: removedPanelID)
        scanner.kick(workspaceId: workspaceID, panelId: retainedPanelID)
        await MainActor.run {
            scanner.unregisterPanel(workspaceId: workspaceID, panelId: removedPanelID)
        }
        await processTable.waitForInvocation()
        let calls = await processTable.recordedTerminalQueries
        #expect(!calls.isEmpty)
    }
}

@MainActor
@Suite("Port scanner generation")
struct PortScannerGenerationTests {
    @Test(
        "A stale panel completion still publishes valid agent ports",
        .timeLimit(.minutes(1))
    )
    func stalePanelCompletionPreservesAgentResults() async throws {
        let workspaceID = UUID()
        let rootIdentity = AgentPIDProcessIdentity(
            pid: 100,
            startSeconds: 10,
            startMicroseconds: 0
        )
        let root = AgentPortRootIdentity(pid: 100, processIdentity: rootIdentity)
        let scanner = PortScanner(processTable: RecordingPortProcessTable())
        let (publications, continuation) = AsyncStream<[Int]>.makeStream(
            bufferingPolicy: .unbounded
        )
        var iterator = publications.makeAsyncIterator()
        scanner.onAgentPortsUpdated = { callbackWorkspaceID, ports in
            guard callbackWorkspaceID == workspaceID else { return false }
            continuation.yield(ports)
            return true
        }
        defer {
            continuation.finish()
            scanner.onAgentPortsUpdated = nil
        }

        let agentRevision = scanner.publicationState.replaceAgentLifecycle(
            workspaceId: workspaceID,
            roots: [root]
        )
        let panelID = UUID()
        scanner.registerTTY(workspaceId: workspaceID, panelId: panelID, ttyName: "ttys999")
        scanner.queue.sync {
            scanner.agentRevisionByWorkspace[workspaceID] = agentRevision
            scanner.trackedAgentWorkspaces.insert(workspaceID)
            scanner.forceAgentResultWorkspaces.insert(workspaceID)
            _ = scanner.scanCoordination.beginPanelScan()
        }
        scanner.unregisterPanel(workspaceId: workspaceID, panelId: panelID)
        scanner.queue.sync {}

        scanner.queue.sync {
            scanner.completePanelScan(
                generation: 0,
                [],
                panelTTYs: [:],
                panelRevisions: [:],
                workspaceIds: [workspaceID],
                agentPortsByWorkspace: [workspaceID: [5173]],
                panelPortOwnersByKey: [:],
                panelProcessIdentitiesByKey: [:],
                agentPortOwnersByWorkspace: [:],
                agentProcessIdentitiesByWorkspace: [:],
                agentRevisions: [workspaceID: agentRevision],
                panelCompletenessByKey: [:],
                panelProcessScopeCompletenessByKey: [:],
                agentCompletenessByWorkspace: [workspaceID: .complete],
                agentProcessScopeCompletenessByWorkspace: [workspaceID: .complete],
                panelLsofEvidence: PortListenerScanResult(
                    values: [:],
                    globallyComplete: true,
                    incompletePIDs: []
                ),
                agentLsofEvidence: nil,
                inspectedPIDs: [],
                requestID: 1
            )
        }

        let publishedPorts = try #require(await iterator.next())
        #expect(publishedPorts == [5173])
    }
}

@Suite("Port scanner retirement end to end")
struct PortScannerPortRetirementTests {
    /// The production burst spans ten seconds, so these tests drive the scanner
    /// on a compressed schedule of the same shape: six scans, one burst, the
    /// same coalesce step. Only the wall-clock spacing shrinks; the scan count
    /// and the ordering the reconciler depends on are unchanged.
    private static let fastBurstOffsets: [TimeInterval] = [0.05, 0.15, 0.3, 0.45, 0.6, 0.75]
    /// Same six-scan burst, but with the final scan left far enough behind the
    /// fifth that a kick issued from inside the fifth scan's port lookup reaches
    /// the scanner queue while the burst still owes exactly one scan, the case
    /// the late-burst test covers. The gap only has to outlast the scanner's own
    /// hop from the fifth timer to that lookup, not a test-task wakeup.
    private static let fastLateBurstOffsets: [TimeInterval] = [0.05, 0.15, 0.3, 0.45, 0.6, 1.6]
    /// The compressed stand-in for the production 200ms coalesce step. No test
    /// here kicks repeatedly while it waits, so nothing is racing this window:
    /// each kick is issued once and the scanner's own guarantee of
    /// `minimumScansPerKick` scans per kick carries the rest.
    private static let fastCoalesceDelay: TimeInterval = 0.01

    /// The compressed schedules above only stand in for production if the
    /// shipped cadence still has the shape they mimic.
    @Test("The production scan schedule keeps its six-scan burst and coalesce window")
    func productionScanScheduleMatchesCompressedShape() {
        #expect(PortScanner.defaultBurstOffsets == [0.5, 1.5, 3, 5, 7.5, 10])
        #expect(PortScanner.defaultCoalesceDelay == 0.2)
        #expect(Self.fastBurstOffsets.count == PortScanner.defaultBurstOffsets.count)
        #expect(Self.fastLateBurstOffsets.count == PortScanner.defaultBurstOffsets.count)
    }

    /// The scan is not free, so hiding the ports detail has to stop it running,
    /// not just stop it being displayed (issue #6123).
    @Test("Hiding the ports detail stops the local scan")
    func disabledPortScanningNeverScans() async throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyName = "ttys903"
        let listenerPID = Int(getpid())
        let processTable = PortLifecycleProcessTable(
            ttyName: ttyName,
            sessionLeaderPID: 1,
            pid: listenerPID,
            port: 4323
        )
        let listenerIdentity = try #require(AgentPIDProcessIdentity(pid: pid_t(listenerPID)))
        let sessionIdentity = TerminalTTYSessionIdentity(processIdentity: listenerIdentity)
        let scanner = PortScanner(
            processTable: processTable,
            listeningPortsProvider: { processTable.listeningPorts(pid: $0) },
            ttySessionIdentityProvider: { _ in sessionIdentity }
        )
        scanner.setScanningEnabled(false)

        await MainActor.run {
            scanner.registerTTY(workspaceId: workspaceId, panelId: panelId, ttyName: ttyName)
        }
        scanner.kick(workspaceId: workspaceId, panelId: panelId)

        let scanned = await processTable.waitForPortScan(1, timeout: .seconds(2))
        #expect(scanned == false, "a disabled scanner must not read any process's ports")
    }

    /// Ports that open while the detail is hidden are never seen, so showing
    /// the detail again has to rescan the panels without waiting for a command.
    @Test("Showing the ports detail again rescans registered panels")
    func reenabledPortScanningRescansRegisteredPanels() async throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyName = "ttys904"
        let listenerPID = Int(getpid())
        let listeningPort = 4324
        let processTable = PortLifecycleProcessTable(
            ttyName: ttyName,
            sessionLeaderPID: 1,
            pid: listenerPID,
            port: listeningPort
        )
        let listenerIdentity = try #require(AgentPIDProcessIdentity(pid: pid_t(listenerPID)))
        let sessionIdentity = TerminalTTYSessionIdentity(processIdentity: listenerIdentity)
        let scanner = PortScanner(
            processTable: processTable,
            listeningPortsProvider: { processTable.listeningPorts(pid: $0) },
            ttySessionIdentityProvider: { _ in sessionIdentity },
            burstOffsets: Self.fastBurstOffsets,
            coalesceDelay: Self.fastCoalesceDelay
        )
        scanner.setScanningEnabled(false)
        let publishedPorts = OSAllocatedUnfairLock(initialState: [[Int]]())

        await MainActor.run {
            scanner.onPortsUpdated = { publishedWorkspaceId, publishedPanelId, ports in
                guard publishedWorkspaceId == workspaceId, publishedPanelId == panelId else { return }
                publishedPorts.withLock { $0.append(ports) }
            }
            scanner.registerTTY(workspaceId: workspaceId, panelId: panelId, ttyName: ttyName)
        }
        scanner.kick(workspaceId: workspaceId, panelId: panelId)
        scanner.setScanningEnabled(true)

        let didPublishListeningPort = await Self.waitForPublication(
            in: publishedPorts,
            matching: { $0 == [listeningPort] },
            pollInterval: .milliseconds(25)
        )
        #expect(didPublishListeningPort, "re-enabling the scanner never rescanned the panel")
    }

    /// Readers other than the sidebar row (socket, CLI, custom sidebars) keep
    /// reading published ports, so hiding the detail must not leave them a
    /// list frozen at the moment scanning stopped.
    @Test("Hiding the ports detail clears the published ports")
    func disablingPortScanningClearsPublishedPorts() async throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyName = "ttys905"
        let listenerPID = Int(getpid())
        let listeningPort = 4325
        let processTable = PortLifecycleProcessTable(
            ttyName: ttyName,
            sessionLeaderPID: 1,
            pid: listenerPID,
            port: listeningPort
        )
        let listenerIdentity = try #require(AgentPIDProcessIdentity(pid: pid_t(listenerPID)))
        let sessionIdentity = TerminalTTYSessionIdentity(processIdentity: listenerIdentity)
        let scanner = PortScanner(
            processTable: processTable,
            listeningPortsProvider: { processTable.listeningPorts(pid: $0) },
            ttySessionIdentityProvider: { _ in sessionIdentity },
            burstOffsets: Self.fastBurstOffsets,
            coalesceDelay: Self.fastCoalesceDelay
        )
        scanner.setScanningEnabled(true)
        let publishedPorts = OSAllocatedUnfairLock(initialState: [[Int]]())

        await MainActor.run {
            scanner.onPortsUpdated = { publishedWorkspaceId, publishedPanelId, ports in
                guard publishedWorkspaceId == workspaceId, publishedPanelId == panelId else { return }
                publishedPorts.withLock { $0.append(ports) }
            }
            scanner.registerTTY(workspaceId: workspaceId, panelId: panelId, ttyName: ttyName)
        }
        scanner.kick(workspaceId: workspaceId, panelId: panelId)

        let didPublishListeningPort = await Self.waitForPublication(
            in: publishedPorts,
            matching: { $0 == [listeningPort] },
            pollInterval: .milliseconds(25)
        )
        try #require(didPublishListeningPort, "the listening port was never published")

        let publicationsBeforeDisable = publishedPorts.withLock { $0.count }
        scanner.setScanningEnabled(false)

        let didClearPorts = await Self.waitForPublication(
            in: publishedPorts,
            after: publicationsBeforeDisable,
            matching: \.isEmpty,
            timeout: .seconds(5),
            pollInterval: .milliseconds(25)
        )
        #expect(didClearPorts, "hiding the ports detail left the published ports in place")
    }

    /// Drives the whole scanner — TTY registration, kick, coalesce, burst,
    /// reconcile, publish — so a break anywhere in that chain surfaces even
    /// when every individual stage still passes its own test.
    @Test("A published port retires after the process stops listening")
    func publishedPortIsRetiredAfterProcessStopsListening() async throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyName = "ttys901"
        // A real terminal's process group is the root-owned session leader plus
        // the user's own processes, so the panel is scanned with launchd
        // standing in for `login` and the test process standing in for the
        // server. Identity and presence stay on the real providers: substituting
        // them is what makes an end-to-end port test pass over a broken scanner.
        let sessionLeaderPID = 1
        let listenerPID = Int(getpid())
        let listeningPort = 4321
        let processTable = PortLifecycleProcessTable(
            ttyName: ttyName,
            sessionLeaderPID: sessionLeaderPID,
            pid: listenerPID,
            port: listeningPort
        )
        let listenerIdentity = try #require(AgentPIDProcessIdentity(pid: pid_t(listenerPID)))
        let sessionIdentity = TerminalTTYSessionIdentity(processIdentity: listenerIdentity)
        let scanner = PortScanner(
            processTable: processTable,
            listeningPortsProvider: { processTable.listeningPorts(pid: $0) },
            ttySessionIdentityProvider: { _ in sessionIdentity },
            burstOffsets: Self.fastBurstOffsets,
            coalesceDelay: Self.fastCoalesceDelay
        )
        let publishedPorts = OSAllocatedUnfairLock(initialState: [[Int]]())

        await MainActor.run {
            scanner.onPortsUpdated = { publishedWorkspaceId, publishedPanelId, ports in
                guard publishedWorkspaceId == workspaceId, publishedPanelId == panelId else { return }
                publishedPorts.withLock { $0.append(ports) }
            }
            scanner.registerTTY(workspaceId: workspaceId, panelId: panelId, ttyName: ttyName)
        }
        scanner.kick(workspaceId: workspaceId, panelId: panelId)

        let didPublishListeningPort = await Self.waitForPublication(
            in: publishedPorts,
            matching: { $0 == [listeningPort] },
            pollInterval: .milliseconds(25)
        )
        try #require(didPublishListeningPort, "the listening port was never published")

        // Only publications recorded after the port stops being held count as
        // retirement; an earlier empty publication is registration noise.
        let publicationsBeforeStop = publishedPorts.withLock { $0.count }
        processTable.stopListening()
        // One kick, not one per poll: a kick guarantees `minimumScansPerKick`
        // scans, which is exactly the number of complete misses the reconciler
        // needs to retire the port.
        scanner.kick(workspaceId: workspaceId, panelId: panelId)

        let didRetirePort = await Self.waitForPublication(
            in: publishedPorts,
            after: publicationsBeforeStop,
            matching: \.isEmpty,
            pollInterval: .milliseconds(25)
        )

        #expect(didRetirePort, "the port was never retired after its process stopped listening")
    }

    /// A kick can arrive near the end of a burst that began for an earlier
    /// shell event. The kick still needs enough later scans to supply the three
    /// complete misses required by `PortScanSnapshotReconciler`.
    @Test("A single late-burst kick still retires a stopped listener")
    func lateBurstKickRetiresStoppedListener() async throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let ttyName = "ttys902"
        let listenerPID = Int(getpid())
        let listeningPort = 4322
        let processTable = PortLifecycleProcessTable(
            ttyName: ttyName,
            sessionLeaderPID: 1,
            pid: listenerPID,
            port: listeningPort
        )
        let listenerIdentity = try #require(AgentPIDProcessIdentity(pid: pid_t(listenerPID)))
        let sessionIdentity = TerminalTTYSessionIdentity(processIdentity: listenerIdentity)
        let scanner = PortScanner(
            processTable: processTable,
            listeningPortsProvider: { processTable.listeningPorts(pid: $0) },
            ttySessionIdentityProvider: { _ in sessionIdentity },
            burstOffsets: Self.fastLateBurstOffsets,
            coalesceDelay: Self.fastCoalesceDelay
        )
        let publishedPorts = OSAllocatedUnfairLock(initialState: [[Int]]())

        await MainActor.run {
            scanner.onPortsUpdated = { publishedWorkspaceId, publishedPanelId, ports in
                guard publishedWorkspaceId == workspaceId, publishedPanelId == panelId else { return }
                publishedPorts.withLock { $0.append(ports) }
            }
            scanner.registerTTY(workspaceId: workspaceId, panelId: panelId, ttyName: ttyName)
        }
        // The fifth scan leaves only the last scan of the six-scan burst.
        // Stopping there means clearing the kick at that scan strands the port
        // after only one complete miss, so the kick must survive the burst.
        // The fixture stops and kicks from inside the fifth port lookup, after
        // that lookup reports the port, so the stop is tied to the scan itself
        // rather than to when this task happens to observe it.
        processTable.stopListening(afterListenerLookup: 5) {
            scanner.kick(workspaceId: workspaceId, panelId: panelId)
        }
        scanner.kick(workspaceId: workspaceId, panelId: panelId)

        let didPublishListeningPort = await Self.waitForPublication(
            in: publishedPorts,
            matching: { $0 == [listeningPort] },
            pollInterval: .milliseconds(10)
        )
        try #require(didPublishListeningPort, "the listening port was never published")
        // Retirement is the first empty publication after the port appeared;
        // an earlier empty publication is registration noise.
        let firstListeningPublication = try #require(
            publishedPorts.withLock { $0.firstIndex(of: [listeningPort]) }
        )

        let didRetirePort = await Self.waitForPublication(
            in: publishedPorts,
            after: firstListeningPublication + 1,
            matching: \.isEmpty,
            timeout: .seconds(12),
            pollInterval: .milliseconds(10)
        )

        #expect(didRetirePort, "a late-burst kick did not schedule enough complete misses")
    }

    /// The process table accepts a full device path, but reports the matching
    /// process's TTY without `/dev/`. The scanner must still attribute the
    /// listener to the panel that registered the full path.
    @Test("A live full-path TTY still attributes its listener")
    func liveFullPathTTYAttributesListener() async throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let registeredTTYName = "/dev/ttys903"
        let processTTYName = "ttys903"
        let listenerPID = Int(getpid())
        let listeningPort = 4323
        let processTable = PortLifecycleProcessTable(
            ttyName: registeredTTYName,
            processTTYName: processTTYName,
            sessionLeaderPID: 1,
            pid: listenerPID,
            port: listeningPort
        )
        let listenerIdentity = try #require(AgentPIDProcessIdentity(pid: pid_t(listenerPID)))
        let sessionIdentity = TerminalTTYSessionIdentity(processIdentity: listenerIdentity)
        let scanner = PortScanner(
            processTable: processTable,
            listeningPortsProvider: { processTable.listeningPorts(pid: $0) },
            ttySessionIdentityProvider: { _ in sessionIdentity }
        )
        let publishedPorts = OSAllocatedUnfairLock(initialState: [[Int]]())

        await MainActor.run {
            scanner.onPortsUpdated = { publishedWorkspaceId, publishedPanelId, ports in
                guard publishedWorkspaceId == workspaceId, publishedPanelId == panelId else { return }
                publishedPorts.withLock { $0.append(ports) }
            }
            scanner.registerTTY(
                workspaceId: workspaceId,
                panelId: panelId,
                ttyName: registeredTTYName
            )
        }
        scanner.kick(workspaceId: workspaceId, panelId: panelId)

        let didPublishListeningPort = await Self.waitForPublication(
            in: publishedPorts,
            matching: { $0 == [listeningPort] },
            timeout: .seconds(6)
        )

        #expect(didPublishListeningPort, "the full-path TTY never received its listener")
    }

    /// Polls rather than sleeping a fixed interval, since the scan burst runs
    /// on real timers whose spacing shifts under load. The deadline bounds only
    /// the failure path: a satisfied predicate returns immediately.
    ///
    /// This only observes; it never kicks. Kicking from the poll loop is a
    /// flake vector, not a nudge: `PortScanner.kick()` re-arms the coalesce
    /// timer whenever no burst is running, so on a loaded runner — where timer
    /// jitter is the same order as the coalesce window — a stream of polls can
    /// cancel that timer forever and no scan ever runs. Each caller kicks once
    /// instead, which the scanner already answers with a guaranteed
    /// `minimumScansPerKick` scans. That makes the poll interval a pure
    /// latency/CPU tradeoff, independent of the coalesce delay.
    private static func waitForPublication(
        in publishedPorts: OSAllocatedUnfairLock<[[Int]]>,
        after startIndex: Int = 0,
        matching predicate: @Sendable ([Int]) -> Bool,
        timeout: Duration = .seconds(20),
        pollInterval: Duration = .milliseconds(500)
    ) async -> Bool {
        func isSatisfied() -> Bool {
            publishedPorts.withLock { $0.dropFirst(startIndex).contains(where: predicate) }
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if isSatisfied() { return true }
            // Cancellation makes the sleep throw immediately; without this the
            // poll would spin until the wall-clock deadline.
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                break
            }
        }
        return isSatisfied()
    }
}

/// Reports one listening port on one TTY until `stopListening()`, after which
/// the process is still alive but owns no sockets.
/// Stubs the process-table half of a scan and stands in for the kernel port
/// lookup, so a panel's whole port lifecycle can be driven without a real
/// listening socket.
private final class PortLifecycleProcessTable: PortProcessTableReading, @unchecked Sendable {
    // Safe: every mutable field lives in `state`, which is only read or
    // written under its lock.
    private struct State {
        var isListening = true
        var portScanCount = 0
        var listenerLookupCount = 0
        var scheduledStop: (lookup: Int, action: @Sendable () -> Void)?
    }

    private let ttyName: String
    private let processTTYName: String
    private let sessionLeaderPID: Int
    private let pid: Int
    private let port: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        ttyName: String,
        processTTYName: String? = nil,
        sessionLeaderPID: Int,
        pid: Int,
        port: Int
    ) {
        self.ttyName = ttyName
        self.processTTYName = processTTYName ?? ttyName
        self.sessionLeaderPID = sessionLeaderPID
        self.pid = pid
        self.port = port
    }

    func stopListening() {
        state.withLock { $0.isListening = false }
    }

    /// The port lookup the scanner calls instead of spawning lsof.
    func listeningPorts(pid queryPID: pid_t) -> ListeningPortLookupResult {
        let (reportsPort, stopAction) = state.withLock { current -> (Bool, (@Sendable () -> Void)?) in
            current.portScanCount += 1
            guard Int(queryPID) == pid else { return (false, nil) }
            current.listenerLookupCount += 1
            let reportsPort = current.isListening
            var action: (@Sendable () -> Void)?
            if let stop = current.scheduledStop, stop.lookup == current.listenerLookupCount {
                current.scheduledStop = nil
                current.isListening = false
                action = stop.action
            }
            return (reportsPort, action)
        }
        stopAction?()
        return .ports(reportsPort ? [port] : [])
    }

    /// Stops listening inside the `target`th lookup of the listener's ports,
    /// after that lookup has reported the port, then runs `action` while the
    /// scan is still in flight. Must be armed before that lookup happens.
    func stopListening(
        afterListenerLookup target: Int,
        then action: @escaping @Sendable () -> Void
    ) {
        state.withLock { $0.scheduledStop = (target, action) }
    }

    func waitForPortScan(_ target: Int, timeout: Duration = .seconds(15)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while state.withLock({ $0.portScanCount }) < target, ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        return state.withLock { $0.portScanCount } >= target
    }

    func processesOnTerminals(
        named ttyNames: [String]
    ) async -> (values: [Int: String], completeness: PortScanCompleteness) {
        // Honor the requested terminals: a scan that asks about another
        // terminal must not be handed this panel's processes.
        let requested = Set(ttyNames)
        guard requested.contains(ttyName) || requested.contains(processTTYName) else {
            return ([:], .complete)
        }
        let canonicalName = PortScanner.canonicalTTYName(processTTYName)
        return ([sessionLeaderPID: canonicalName, pid: canonicalName], .complete)
    }

    func parentsByPID() async -> (values: [Int: Int], completeness: PortScanCompleteness) {
        ([pid: 1], .complete)
    }
}

/// Answers every process-tree read with a fixed parent map, optionally running
/// a callback inside the read so a test can change state mid-scan.
private actor StubPortProcessTable: PortProcessTableReading {
    let parents: [Int: Int]
    let onRead: (@Sendable () -> Void)?

    init(parents: [Int: Int], onRead: (@Sendable () -> Void)? = nil) {
        self.parents = parents
        self.onRead = onRead
    }

    func processesOnTerminals(
        named ttyNames: [String]
    ) async -> (values: [Int: String], completeness: PortScanCompleteness) {
        onRead?()
        return ([:], .complete)
    }

    func parentsByPID() async -> (values: [Int: Int], completeness: PortScanCompleteness) {
        onRead?()
        return (parents, .complete)
    }
}
