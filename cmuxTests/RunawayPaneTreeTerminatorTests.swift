import CmuxFoundation
import CmuxMemoryPressure
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Records the synchronous OS signal seam from concurrent callers. All mutable
/// state is protected by the lock; failures are configured per signal.
private final class TerminationSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int32] = []
    let acceptsTerm: Bool

    init(acceptsTerm: Bool = true) { self.acceptsTerm = acceptsTerm }

    func send(_ group: Int, _ signal: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        values.append(signal)
        return signal != SIGTERM || acceptsTerm
    }

    var recorded: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private actor TerminationCensus {
    let snapshot: CmuxTopProcessSnapshot
    private var reads = 0
    private(set) var authorized = true

    init(_ snapshot: CmuxTopProcessSnapshot) { self.snapshot = snapshot }

    func read(revokeOnSecondRead: Bool = false) -> CmuxTopProcessSnapshot {
        reads += 1
        if revokeOnSecondRead && reads == 2 { authorized = false }
        return snapshot
    }
}

@MainActor
private final class LiveTerminationPanes {
    var panes: [PaneMemoryDescriptor] = []
}

@Suite
struct RunawayPaneTreeTerminatorTests {
    private let tty: Int64 = 0x1600_0003
    private let selector = RunawaySessionSelector(appProcessID: 50, appProcessGroupID: 50, thresholdBytes: 30)

    private func snapshot(started: Int64 = 1_000, complete: Bool = true) -> CmuxTopProcessSnapshot {
        let processes = [(100, 50, "login"), (200, 100, "zsh"), (300, 200, "node")].map { pid, parent, name in
            CmuxTopProcessInfo(
                pid: pid,
                processIdentity: AgentPIDProcessIdentity(
                    pid: pid_t(pid), startSeconds: pid == 300 ? started : 1_000, startMicroseconds: 0
                ),
                parentPID: parent, name: name, path: nil, ttyDevice: tty,
                cmuxWorkspaceID: nil, cmuxSurfaceID: nil, cmuxAttributionReason: nil,
                processGroupID: pid, terminalProcessGroupID: 300, cpuPercent: 0,
                memoryBytes: 10, memorySource: .physicalFootprint,
                residentBytes: 10, residentMemorySource: .residentSize, virtualBytes: 0, threadCount: 1
            )
        }
        return CmuxTopProcessSnapshot(
            processes: processes, sampledAt: Date(), includesProcessDetails: false,
            includesCMUXScope: false, enumerationIsComplete: complete
        )
    }

    @Test
    func reusedGroupBeforeTermIsNeverSignalled() async throws {
        let initial = try #require(snapshot().runawaySessionCensus())
        let reused = snapshot(started: 2_000)
        let signals = TerminationSignals()
        let terminator = RunawayPaneTreeTerminator(
            snapshotProvider: { reused }, signalProcessGroup: signals.send,
            waitForGraceDeadline: { Issue.record("No signal means no grace period"); return true }
        )
        let stopped = await terminator.terminate(processGroupIDs: [300], ttyDevice: tty, census: initial, selector: selector)
        #expect(!stopped)
        #expect(signals.recorded.isEmpty)
    }

    @Test
    func incompletePreTermCensusFailsClosed() async throws {
        let initial = try #require(snapshot().runawaySessionCensus())
        let incomplete = snapshot(complete: false)
        let signals = TerminationSignals()
        let terminator = RunawayPaneTreeTerminator(
            snapshotProvider: { incomplete }, signalProcessGroup: signals.send, waitForGraceDeadline: { true }
        )
        let stopped = await terminator.terminate(processGroupIDs: [300], ttyDevice: tty, census: initial, selector: selector)
        #expect(!stopped)
        #expect(signals.recorded.isEmpty)
    }

    @Test
    func rejectedTermDoesNotEscalateOrReportSuccess() async throws {
        let current = snapshot()
        let initial = try #require(current.runawaySessionCensus())
        let signals = TerminationSignals(acceptsTerm: false)
        let terminator = RunawayPaneTreeTerminator(
            snapshotProvider: { current }, signalProcessGroup: signals.send,
            waitForGraceDeadline: { Issue.record("Rejected signals must not escalate"); return true }
        )
        let stopped = await terminator.terminate(processGroupIDs: [300], ttyDevice: tty, census: initial, selector: selector)
        #expect(!stopped)
        #expect(signals.recorded == [SIGTERM])
    }

    @Test
    func revokingConsentDuringFollowUpCensusPreventsKill() async throws {
        let current = snapshot()
        let initial = try #require(current.runawaySessionCensus())
        let source = TerminationCensus(current)
        let signals = TerminationSignals()
        let terminator = RunawayPaneTreeTerminator(
            snapshotProvider: { await source.read(revokeOnSecondRead: true) },
            signalProcessGroup: signals.send, waitForGraceDeadline: { true }
        )
        let stopped = await terminator.terminate(
            processGroupIDs: [300], ttyDevice: tty, census: initial, selector: selector,
            shouldEscalate: { await source.authorized }
        )
        #expect(stopped)
        #expect(signals.recorded == [SIGTERM])
    }

    @Test
    func revokedTargetBeforeTermNeverSignals() async throws {
        let current = snapshot()
        let initial = try #require(current.runawaySessionCensus())
        let signals = TerminationSignals()
        let terminator = RunawayPaneTreeTerminator(
            snapshotProvider: { current }, signalProcessGroup: signals.send, waitForGraceDeadline: { true }
        )
        let stopped = await terminator.terminate(
            processGroupIDs: [300], ttyDevice: tty, census: initial, selector: selector,
            shouldTerminate: { _ in false }
        )
        #expect(!stopped)
        #expect(signals.recorded.isEmpty)
    }

    @Test
    func cancellationDuringFollowUpCensusPreventsKill() async throws {
        let current = snapshot()
        let initial = try #require(current.runawaySessionCensus())
        let source = TerminationCensus(current)
        let signals = TerminationSignals()
        let terminator = RunawayPaneTreeTerminator(
            snapshotProvider: {
                let snapshot = await source.read(revokeOnSecondRead: true)
                if await !source.authorized { withUnsafeCurrentTask { $0?.cancel() } }
                return snapshot
            },
            signalProcessGroup: signals.send, waitForGraceDeadline: { true }
        )
        let task = Task {
            await terminator.terminate(processGroupIDs: [300], ttyDevice: tty, census: initial, selector: selector)
        }
        #expect(await task.value)
        #expect(signals.recorded == [SIGTERM])
    }

    @Test @MainActor
    func closingPaneDuringAutomaticCensusPreventsAllSignals() async throws {
        let state = LiveTerminationPanes()
        state.panes = [PaneMemoryDescriptor(
            workspaceId: UUID(), panelId: UUID(), workspaceTitle: "work", paneTitle: "job",
            ttyName: "/dev/ttys003", foregroundPID: 300
        )]
        let current = snapshot()
        let aggregate = MemoryPressureAggregatePolicy.default.evaluate(sample: MemoryPressureAggregateSample(
            source: .coalition, aggregateBytes: 30, physicalMemoryBytes: 32, availableMemoryBytes: 1,
            processCount: 3, missingProcessCount: 0, missingReason: nil, sampledAt: Date()
        ))
        #expect(aggregate.severity == .critical)
        let signals = TerminationSignals()
        let device = tty
        let responder = RunawayPaneTreeMemoryPressureResponder(
            isEnabled: { true }, paneProvider: { state.panes }, thresholdBytes: { 30 },
            snapshotProvider: {
                await MainActor.run { state.panes = [] }
                return current
            },
            aggregateProvider: { _ in aggregate },
            signalProcessGroup: signals.send, waitForGraceDeadline: { true },
            ttyDevice: { _ in device }, appProcessID: 50, appProcessGroupID: 50
        )
        // A threshold that can clear after stopping the job is necessary to
        // exercise termination, rather than merely passing an empty selection.
        let active = try #require(selector.selection(ttyDevice: tty, in: try #require(current.runawaySessionCensus()), aggregateBytes: 30))
        #expect(active.processGroupIDs == [300])
        _ = responder.shedMemory(for: MemoryPressureSnapshot(
            severity: .critical, physicalFootprintBytes: nil, aggregateMemoryPressure: aggregate, sampledAt: Date()
        ))
        await responder.evaluationTask?.value
        #expect(signals.recorded.isEmpty)
    }

    @Test
    func cachedCriticalAggregateCannotAuthorizeRecoveredPressure() async throws {
        let current = snapshot()
        let aggregate = MemoryPressureAggregatePolicy.default.evaluate(sample: MemoryPressureAggregateSample(
            source: .coalition, aggregateBytes: 60, physicalMemoryBytes: 64, availableMemoryBytes: 1,
            processCount: 3, missingProcessCount: 0, missingReason: nil, sampledAt: Date()
        ))
        let recovered = MemoryPressureAggregatePolicy.default.evaluate(sample: MemoryPressureAggregateSample(
            source: .coalition, aggregateBytes: 30, physicalMemoryBytes: 64, availableMemoryBytes: 32,
            processCount: 3, missingProcessCount: 0, missingReason: nil, sampledAt: Date()
        ))
        #expect(recovered.severity == .normal)
        let signals = TerminationSignals()
        let device = tty
        let targets = await RunawayPaneTreeMemoryPressureResponder.evaluate(
            descriptors: [PaneMemoryDescriptor(
                workspaceId: UUID(), panelId: UUID(), workspaceTitle: "work", paneTitle: "job",
                ttyName: "/dev/ttys003", foregroundPID: 300
            )],
            selector: selector, knownAggregate: aggregate, sampledAt: Date(), snapshotProvider: { current },
            aggregateProvider: { _ in recovered }, signalProcessGroup: signals.send,
            waitForGraceDeadline: { true }, ttyDevice: { _ in device }
        )
        #expect(targets.isEmpty)
        #expect(signals.recorded.isEmpty)
    }
}
