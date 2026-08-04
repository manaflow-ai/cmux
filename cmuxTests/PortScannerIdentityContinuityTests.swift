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

@Suite("Port scanner identity continuity")
struct PortScannerIdentityContinuityTests {
    @Test("Confirmed absent roots age out while inaccessible roots retain transient ports")
    func rootPresenceControlsNegativeEvidence() {
        let workspaceID = UUID()
        let expectedIdentity = AgentPIDProcessIdentity(
            pid: 100,
            startSeconds: 10,
            startMicroseconds: 0
        )
        let root = AgentPortRootIdentity(pid: 100, processIdentity: expectedIdentity)
        let absentScanner = PortScanner(
            processIdentityProvider: { _ in nil },
            processPresenceProvider: { _ in .absent }
        )
        let inaccessibleScanner = PortScanner(
            processIdentityProvider: { _ in nil },
            processPresenceProvider: { _ in .present }
        )
        let absent = absentScanner.validateAgentRoots([workspaceID: [root]])
        let inaccessible = inaccessibleScanner.validateAgentRoots([workspaceID: [root]])

        var absentSnapshot = PortScanSnapshotReconciler<UUID>()
        absentSnapshot.reconcile(
            scannedPorts: [workspaceID: [4200]],
            scannedKeys: [workspaceID],
            trackedKeys: [workspaceID],
            completeness: .complete
        )
        for _ in 0..<2 {
            let snapshot = absentSnapshot.reconcile(
                scannedPorts: [:],
                scannedKeys: [workspaceID],
                trackedKeys: [workspaceID],
                completeness: absent.completenessByWorkspace[workspaceID, default: .incomplete]
            )
            #expect(snapshot[workspaceID] == [4200])
        }
        let expired = absentSnapshot.reconcile(
            scannedPorts: [:],
            scannedKeys: [workspaceID],
            trackedKeys: [workspaceID],
            completeness: absent.completenessByWorkspace[workspaceID, default: .incomplete]
        )

        var inaccessibleSnapshot = PortScanSnapshotReconciler<UUID>()
        inaccessibleSnapshot.reconcile(
            scannedPorts: [workspaceID: [4200]],
            scannedKeys: [workspaceID],
            trackedKeys: [workspaceID],
            completeness: .complete
        )
        let retained = inaccessibleSnapshot.reconcile(
            scannedPorts: [:],
            scannedKeys: [workspaceID],
            trackedKeys: [workspaceID],
            completeness: inaccessible.completenessByWorkspace[workspaceID, default: .complete]
        )

        #expect(absent.completenessByWorkspace[workspaceID] == .complete)
        #expect(expired[workspaceID] == nil)
        #expect(inaccessible.completenessByWorkspace[workspaceID] == .incomplete)
        #expect(retained[workspaceID] == [4200])
    }

    @Test("A descendant PID reused during lsof cannot attribute replacement ports")
    func descendantReuseIsAuthoritativeNegative() throws {
        let workspaceID = UUID()
        let capturedIdentity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 0
        )
        let replacementIdentity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 20,
            startMicroseconds: 0
        )
        // Serializes synchronous identity-provider reads with the simulated lsof transition.
        let state = OSAllocatedUnfairLock(initialState: IdentityState(identities: [101: capturedIdentity]))
        let scanner = makeScanner(state: state)
        let captured = scanner.captureAgentPIDIdentities(
            ownershipByPID: [101: [workspaceID]],
            workspaceIds: [workspaceID]
        )

        state.withLock { $0.identities[101] = replacementIdentity }
        let revalidated = scanner.revalidateAgentPIDIdentities(
            ownershipByPID: captured.ownershipByPID,
            identitiesByPID: captured.identitiesByPID,
            workspaceIds: [workspaceID]
        )

        #expect(captured.ownershipByPID == [101: [workspaceID]])
        #expect(revalidated.ownershipByPID.isEmpty)
        #expect(revalidated.completenessByWorkspace[workspaceID] == .complete)
    }

    @Test("Panel PID ownership requires stable birth identity and a fresh TTY mapping")
    func panelPIDOwnershipRequiresIdentityAndFreshGraph() {
        let capturedIdentity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 10,
            startMicroseconds: 0
        )
        let replacementIdentity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 20,
            startMicroseconds: 0
        )
        // Serializes identity-provider reads with the simulated lsof transition.
        let state = OSAllocatedUnfairLock(
            initialState: IdentityState(identities: [101: capturedIdentity])
        )
        let scanner = makeScanner(state: state)
        let captured = scanner.capturePIDIdentities([101])
        let capturedPIDToTTY = [101: "ttys010"]

        let stable = scanner.revalidatePanelPIDOwnership(
            capturedPIDToTTY: capturedPIDToTTY,
            capturedIdentitiesByPID: captured.identitiesByPID,
            refreshedPIDToTTY: capturedPIDToTTY
        )
        let moved = scanner.revalidatePanelPIDOwnership(
            capturedPIDToTTY: capturedPIDToTTY,
            capturedIdentitiesByPID: captured.identitiesByPID,
            refreshedPIDToTTY: [101: "ttys011"]
        )
        state.withLock { $0.identities[101] = replacementIdentity }
        let recycled = scanner.revalidatePanelPIDOwnership(
            capturedPIDToTTY: capturedPIDToTTY,
            capturedIdentitiesByPID: captured.identitiesByPID,
            refreshedPIDToTTY: capturedPIDToTTY
        )

        #expect(stable.values == capturedPIDToTTY)
        #expect(moved.values.isEmpty)
        #expect(recycled.values.isEmpty)
        #expect(recycled.incompletePIDs.isEmpty)
    }

    @Test("A root PID recycled after tree validation cannot attribute replacement ports")
    func rootReuseAfterTreeValidationDropsReplacementAttribution() async throws {
        let recycledWorkspaceID = UUID()
        let healthyWorkspaceID = UUID()
        let recordedRootIdentity = AgentPIDProcessIdentity(
            pid: 100,
            startSeconds: 10,
            startMicroseconds: 0
        )
        let replacementRootIdentity = AgentPIDProcessIdentity(
            pid: 100,
            startSeconds: 20,
            startMicroseconds: 0
        )
        let descendantIdentity = AgentPIDProcessIdentity(
            pid: 101,
            startSeconds: 11,
            startMicroseconds: 0
        )
        let root = AgentPortRootIdentity(pid: 100, processIdentity: recordedRootIdentity)
        let nestedRoot = AgentPortRootIdentity(pid: 101, processIdentity: descendantIdentity)
        // The first two root reads are expandAgentProcessTree's pre/post-ps fence.
        // The third simulates PID reuse immediately before PID identity capture.
        let state = OSAllocatedUnfairLock(initialState: RootReuseState(
            rootIdentityReads: 0,
            recordedRootIdentity: recordedRootIdentity,
            replacementRootIdentity: replacementRootIdentity,
            descendantIdentity: descendantIdentity
        ))
        let runner = RootReuseCommandRunner(result: CommandResult(
            stdout: "100 1\n101 100\n",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))
        let scanner = PortScanner(
            commandRunner: runner,
            processIdentityProvider: { pid in state.withLock { $0.identity(for: pid) } },
            processPresenceProvider: { _ in .present }
        )
        let rootsByWorkspace = [
            recycledWorkspaceID: Set([root]),
            healthyWorkspaceID: Set([nestedRoot]),
        ]
        let expanded = await scanner.expandAgentProcessTree(
            agentRootsByWorkspace: rootsByWorkspace
        )
        let captured = scanner.captureAgentPIDIdentities(
            ownershipByPID: expanded.values,
            workspaceIds: [recycledWorkspaceID, healthyWorkspaceID]
        )

        let finalized = await scanner.finalizeAgentPIDOwnership(
            rootsByWorkspace: rootsByWorkspace,
            capturedOwnershipByPID: captured.ownershipByPID,
            capturedIdentitiesByPID: captured.identitiesByPID,
            workspaceIds: [recycledWorkspaceID, healthyWorkspaceID]
        )
        let replacementPorts = [100: Set([4200]), 101: Set([4300])]
        let attributedPorts = replacementPorts.reduce(into: [UUID: Set<Int>]()) { result, item in
            for owner in finalized.ownershipByPID[item.key] ?? [] {
                result[owner, default: []].formUnion(item.value)
            }
        }

        #expect(captured.identitiesByPID[100] == replacementRootIdentity)
        #expect(captured.ownershipByPID[101] == [recycledWorkspaceID, healthyWorkspaceID])
        #expect(finalized.ownershipByPID == [101: [healthyWorkspaceID]])
        #expect(finalized.completenessByWorkspace[recycledWorkspaceID] == .complete)
        #expect(finalized.completenessByWorkspace[healthyWorkspaceID] == .complete)
        #expect(attributedPorts[recycledWorkspaceID] == nil)
        #expect(attributedPorts[healthyWorkspaceID] == [4300])
    }

    @Test("A post-capture process graph rejects stale descendant ownership")
    func postCaptureGraphRejectsReusedDescendant() async {
        let workspaceID = UUID()
        let rootIdentity = AgentPIDProcessIdentity(pid: 100, startSeconds: 10, startMicroseconds: 0)
        let replacementIdentity = AgentPIDProcessIdentity(pid: 101, startSeconds: 20, startMicroseconds: 0)
        let root = AgentPortRootIdentity(pid: 100, processIdentity: rootIdentity)
        let runner = RootReuseCommandRunner(
            firstResult: CommandResult(
                stdout: "100 1\n101 100\n",
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            ),
            secondResult: CommandResult(
                stdout: "100 1\n101 999\n",
                stderr: "",
                exitStatus: 0,
                timedOut: false,
                executionError: nil
            )
        )
        let scanner = PortScanner(
            commandRunner: runner,
            processIdentityProvider: { pid in
                switch pid {
                case 100: rootIdentity
                case 101: replacementIdentity
                default: nil
                }
            },
            processPresenceProvider: { _ in .present }
        )
        let rootsByWorkspace = [workspaceID: Set([root])]
        let expanded = await scanner.expandAgentProcessTree(agentRootsByWorkspace: rootsByWorkspace)
        let captured = scanner.captureAgentPIDIdentities(
            ownershipByPID: expanded.values,
            workspaceIds: [workspaceID]
        )

        let finalized = await scanner.finalizeAgentPIDOwnership(
            rootsByWorkspace: rootsByWorkspace,
            capturedOwnershipByPID: captured.ownershipByPID,
            capturedIdentitiesByPID: captured.identitiesByPID,
            workspaceIds: [workspaceID]
        )

        #expect(captured.ownershipByPID[101] == [workspaceID])
        #expect(finalized.ownershipByPID == [100: [workspaceID]])
        #expect(finalized.completenessByWorkspace[workspaceID] == .complete)
    }

    @Test("A failed process graph preserves confirmed-absent workspace evidence")
    func processGraphFailureIsScopedToValidRoots() async {
        let absentWorkspaceID = UUID()
        let validWorkspaceID = UUID()
        let absentIdentity = AgentPIDProcessIdentity(pid: 100, startSeconds: 10, startMicroseconds: 0)
        let validIdentity = AgentPIDProcessIdentity(pid: 200, startSeconds: 20, startMicroseconds: 0)
        let rootsByWorkspace = [
            absentWorkspaceID: Set([AgentPortRootIdentity(pid: 100, processIdentity: absentIdentity)]),
            validWorkspaceID: Set([AgentPortRootIdentity(pid: 200, processIdentity: validIdentity)]),
        ]
        let runner = RootReuseCommandRunner(result: CommandResult(
            stdout: "200 1\n",
            stderr: "",
            exitStatus: 1,
            timedOut: false,
            executionError: nil
        ))
        let scanner = PortScanner(
            commandRunner: runner,
            processIdentityProvider: { pid in pid == validIdentity.pid ? validIdentity : nil },
            processPresenceProvider: { pid in pid == absentIdentity.pid ? .absent : .present }
        )

        let expanded = await scanner.expandAgentProcessTree(agentRootsByWorkspace: rootsByWorkspace)

        #expect(expanded.completenessByWorkspace[absentWorkspaceID] == .complete)
        #expect(expanded.completenessByWorkspace[validWorkspaceID] == .incomplete)

        let finalized = await scanner.finalizeAgentPIDOwnership(
            rootsByWorkspace: rootsByWorkspace,
            capturedOwnershipByPID: [200: [validWorkspaceID]],
            capturedIdentitiesByPID: [200: validIdentity],
            workspaceIds: [absentWorkspaceID, validWorkspaceID]
        )

        #expect(finalized.completenessByWorkspace[absentWorkspaceID] == .complete)
        #expect(finalized.completenessByWorkspace[validWorkspaceID] == .incomplete)
    }

    @Test("No agent ownership skips post-capture process enumeration")
    func noAgentOwnershipSkipsFreshProcessGraph() async {
        let workspaceID = UUID()
        let runner = RootReuseCommandRunner(result: CommandResult(
            stdout: "",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        ))
        let scanner = PortScanner(commandRunner: runner)

        let finalized = await scanner.finalizeAgentPIDOwnership(
            rootsByWorkspace: [:],
            capturedOwnershipByPID: [:],
            capturedIdentitiesByPID: [:],
            workspaceIds: [workspaceID]
        )
        let runCount = await runner.runCount()

        #expect(finalized.ownershipByPID.isEmpty)
        #expect(finalized.completenessByWorkspace[workspaceID] == .complete)
        #expect(runCount == 0)
    }

    @Test("Unavailable post-lsof identity is incomplete only for owning workspaces")
    func unavailableIdentityIsWorkspaceScoped() {
        let unavailableWorkspaceID = UUID()
        let healthyWorkspaceID = UUID()
        let firstIdentity = AgentPIDProcessIdentity(pid: 101, startSeconds: 10, startMicroseconds: 0)
        let secondIdentity = AgentPIDProcessIdentity(pid: 202, startSeconds: 20, startMicroseconds: 0)
        // Serializes synchronous identity and presence reads with the simulated lsof transition.
        let state = OSAllocatedUnfairLock(initialState: IdentityState(
            identities: [101: firstIdentity, 202: secondIdentity]
        ))
        let scanner = makeScanner(state: state)
        let captured = scanner.captureAgentPIDIdentities(
            ownershipByPID: [
                101: [unavailableWorkspaceID],
                202: [healthyWorkspaceID],
            ],
            workspaceIds: [unavailableWorkspaceID, healthyWorkspaceID]
        )

        state.withLock {
            $0.identities.removeValue(forKey: 101)
            $0.presenceByPID[101] = .present
        }
        let revalidated = scanner.revalidateAgentPIDIdentities(
            ownershipByPID: captured.ownershipByPID,
            identitiesByPID: captured.identitiesByPID,
            workspaceIds: [unavailableWorkspaceID, healthyWorkspaceID]
        )

        #expect(revalidated.ownershipByPID == [202: [healthyWorkspaceID]])
        #expect(revalidated.completenessByWorkspace[unavailableWorkspaceID] == .incomplete)
        #expect(revalidated.completenessByWorkspace[healthyWorkspaceID] == .complete)
    }

    @Test("ps status one is complete only for an empty no-match result")
    func psNoMatchStatusIsEvidenceSensitive() async {
        let emptyScan = await PortScanner(commandRunner: RootReuseCommandRunner(result: CommandResult(
            stdout: "",
            stderr: "",
            exitStatus: 1,
            timedOut: false,
            executionError: nil
        ))).runPS(ttyList: "ttys001")
        let partialScan = await PortScanner(commandRunner: RootReuseCommandRunner(result: CommandResult(
            stdout: "123 ttys001\n",
            stderr: "",
            exitStatus: 1,
            timedOut: false,
            executionError: nil
        ))).runPS(ttyList: "ttys001")
        let diagnosticScan = await PortScanner(commandRunner: RootReuseCommandRunner(result: CommandResult(
            stdout: "",
            stderr: "ps: inspection failed\n",
            exitStatus: 1,
            timedOut: false,
            executionError: nil
        ))).runPS(ttyList: "ttys001")

        #expect(emptyScan.values.isEmpty)
        #expect(emptyScan.completeness == .complete)
        #expect(partialScan.values == [123: "ttys001"])
        #expect(partialScan.completeness == .incomplete)
        #expect(diagnosticScan.values.isEmpty)
        #expect(diagnosticScan.completeness == .incomplete)
    }

    private struct IdentityState: Sendable {
        var identities: [Int: AgentPIDProcessIdentity]
        var presenceByPID: [Int: PIDPresence] = [:]
    }

    private struct RootReuseState: Sendable {
        var rootIdentityReads: Int
        let recordedRootIdentity: AgentPIDProcessIdentity
        let replacementRootIdentity: AgentPIDProcessIdentity
        let descendantIdentity: AgentPIDProcessIdentity

        mutating func identity(for pid: pid_t) -> AgentPIDProcessIdentity? {
            switch pid {
            case recordedRootIdentity.pid:
                defer { rootIdentityReads += 1 }
                return rootIdentityReads < 2 ? recordedRootIdentity : replacementRootIdentity
            case descendantIdentity.pid:
                return descendantIdentity
            default:
                return nil
            }
        }
    }

    private func makeScanner(state: OSAllocatedUnfairLock<IdentityState>) -> PortScanner {
        PortScanner(
            processIdentityProvider: { pid in state.withLock { $0.identities[Int(pid)] } },
            processPresenceProvider: { pid in
                state.withLock { $0.presenceByPID[Int(pid), default: .present] }
            }
        )
    }
}

private actor RootReuseCommandRunner: CommandRunning {
    private let results: [CommandResult]
    private var nextResultIndex = 0

    init(result: CommandResult) {
        self.results = [result]
    }

    init(firstResult: CommandResult, secondResult: CommandResult) {
        self.results = [firstResult, secondResult]
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        let index = min(nextResultIndex, results.count - 1)
        nextResultIndex += 1
        return results[index]
    }

    func runCount() -> Int {
        nextResultIndex
    }
}
