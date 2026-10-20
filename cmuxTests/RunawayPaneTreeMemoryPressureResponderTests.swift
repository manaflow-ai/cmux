import Darwin
import Foundation
import Testing
import CmuxMemoryPressure

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(processGroupID: Int, signal: Int32)] = []

    func record(_ processGroupID: Int, _ signal: Int32) {
        lock.lock()
        recorded.append((processGroupID, signal))
        lock.unlock()
    }

    func groups(for signal: Int32) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.filter { $0.signal == signal }.map(\.processGroupID).sorted()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded.count
    }
}

private final class SnapshotSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [CmuxTopProcessSnapshot]

    init(_ snapshots: [CmuxTopProcessSnapshot]) {
        self.snapshots = snapshots
    }

    func next() -> CmuxTopProcessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0]
    }
}

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/22273:
/// one pane's runaway `next dev` session must be stopped under critical
/// aggregate pressure instead of taking the whole app down, without touching
/// the pane's login or shell, or anything outside the pane's tty.
@Suite
struct RunawayPaneTreeMemoryPressureResponderTests {
    private static let gb: Int64 = 1024 * 1024 * 1024
    private static let threshold: Int64 = 8 * gb
    private static let paneTTY: Int64 = 0x1600_0003
    private static let paneTTYName = "/dev/ttys003"
    private static let app = RunawayPaneTreeAppIdentity(processID: 50, processGroupID: 50)
    private static let ttyDevice: RunawayPaneTreeSelection.TTYDeviceResolver = {
        $0 == paneTTYName ? paneTTY : nil
    }

    private let workspaceID = UUID()
    private let paneID = UUID()

    private func descriptor(ttyName: String? = Self.paneTTYName) -> PaneMemoryDescriptor {
        PaneMemoryDescriptor(
            workspaceId: workspaceID,
            panelId: paneID,
            workspaceTitle: "Workspace",
            paneTitle: "next dev",
            ttyName: ttyName,
            foregroundPID: 300
        )
    }

    private func process(
        _ pid: Int,
        parent: Int,
        name: String,
        group: Int,
        bytes: Int64,
        tty: Int64? = Self.paneTTY,
        surface: UUID? = nil
    ) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid, parentPID: parent, name: name, path: nil, ttyDevice: tty,
            cmuxWorkspaceID: surface == nil ? nil : workspaceID, cmuxSurfaceID: surface,
            cmuxAttributionReason: nil,
            processGroupID: group, terminalProcessGroupID: 300, cpuPercent: 0,
            memoryBytes: bytes, memorySource: .physicalFootprint,
            residentBytes: bytes, residentMemorySource: .residentSize,
            virtualBytes: 0, threadCount: 1
        )
    }

    private func census(
        _ processes: [CmuxTopProcessInfo],
        enumerationIsComplete: Bool = true
    ) -> CmuxTopProcessSnapshot {
        CmuxTopProcessSnapshot(
            processes: processes,
            sampledAt: Date(),
            includesProcessDetails: false,
            includesCMUXScope: false,
            enumerationIsComplete: enumerationIsComplete
        )
    }

    /// cmux(50) -> login(100) -> zsh(200), the pane's session root and shell.
    private func session(loginParent: Int = 50) -> [CmuxTopProcessInfo] {
        [
            process(100, parent: loginParent, name: "login", group: 100, bytes: 4_000_000),
            process(200, parent: 100, name: "zsh", group: 200, bytes: 8_000_000),
        ]
    }

    /// `next dev`(300) and its node workers in job group 300, like the
    /// reported fork storm. Orphaned workers were reparented to launchd.
    private func runawayJob(
        workerCount: Int = 60,
        workerBytes: Int64 = 512 * 1024 * 1024,
        includeLeader: Bool = true,
        workerParent: Int = 300
    ) -> [CmuxTopProcessInfo] {
        var processes: [CmuxTopProcessInfo] = []
        if includeLeader {
            processes.append(process(300, parent: 200, name: "node", group: 300, bytes: Self.gb))
        }
        for index in 0..<workerCount {
            processes.append(
                process(1_000 + index, parent: workerParent, name: "node", group: 300, bytes: workerBytes)
            )
        }
        return processes
    }

    private func targets(
        _ snapshot: CmuxTopProcessSnapshot,
        aggregateGB: Int64 = 32,
        descriptor: PaneMemoryDescriptor? = nil
    ) -> [RunawayPaneTreeTarget] {
        RunawayPaneTreeSelection.targets(
            descriptors: [descriptor ?? self.descriptor()],
            snapshot: snapshot,
            aggregateBytes: UInt64(aggregateGB * Self.gb),
            thresholdBytes: Self.threshold,
            app: Self.app,
            ttyDevice: Self.ttyDevice
        )
    }

    private func aggregate(
        bytes: UInt64,
        physicalMemory: UInt64 = 64 * 1024 * 1024 * 1024,
        missingProcessCount: Int = 0
    ) -> MemoryPressureAggregateSnapshot {
        // A missing record only makes a descendant-tree sample a lower bound.
        let sample = MemoryPressureAggregateSample(
            source: missingProcessCount > 0 ? .descendantProcessTree : .coalition,
            aggregateBytes: bytes,
            physicalMemoryBytes: physicalMemory,
            availableMemoryBytes: 32 * 1024 * 1024 * 1024,
            processCount: 64,
            missingProcessCount: missingProcessCount,
            missingReason: missingProcessCount > 0 ? .processExitRace : nil,
            sampledAt: Date()
        )
        return MemoryPressureAggregatePolicy.default.evaluate(sample: sample)
    }

    private func evaluate(
        knownAggregate: MemoryPressureAggregateSnapshot?,
        resampledAggregate: MemoryPressureAggregateSnapshot? = nil,
        snapshots: SnapshotSequence,
        recorder: SignalRecorder,
        graceElapses: Bool = true
    ) async -> [RunawayPaneTreeTarget] {
        let resampled = resampledAggregate ?? MemoryPressureAggregatePolicy.default.evaluate(
            sample: .unavailable(sampledAt: Date())
        )
        return await RunawayPaneTreeMemoryPressureResponder.evaluate(
            descriptors: [descriptor()],
            thresholdBytes: Self.threshold,
            knownAggregate: knownAggregate,
            sampledAt: Date(),
            snapshotProvider: { snapshots.next() },
            aggregateProvider: { _ in resampled },
            signalProcessGroup: { recorder.record($0, $1) },
            waitForGraceDeadline: { graceElapses },
            app: Self.app,
            ttyDevice: Self.ttyDevice
        )
    }

    // MARK: Selection

    @Test
    func selectsOnlyTheRunawayJobGroupNeverLoginOrShell() {
        let selected = targets(census(session() + runawayJob()))

        #expect(selected.count == 1)
        #expect(selected.first?.key == descriptor().key)
        #expect(selected.first?.processGroupIDs == [300])
        #expect(selected.first?.processCount == 63)
    }

    @Test
    func orphanedWorkersOnThePaneTTYStayInTheRunawayGroup() {
        // Workers whose parent exited were reparented to launchd but keep the
        // pane's tty; they must not make their own group look like a root.
        let selected = targets(census(session() + runawayJob(includeLeader: false, workerParent: 1)))

        #expect(selected.first?.processGroupIDs == [300])
    }

    @Test
    func detachedAppOutsideThePaneTTYIsNeverMeasuredOrSignalled() {
        // An app launched from the pane inherits its surface environment but
        // runs in its own sessions without the pane's tty. Only the pane's own
        // runaway job may be selected.
        var processes = session() + runawayJob()
        processes.append(process(700, parent: 1, name: "Code", group: 700, bytes: 20 * Self.gb,
                                 tty: nil, surface: paneID))
        processes.append(process(701, parent: 700, name: "zsh", group: 701, bytes: 20 * Self.gb,
                                 tty: 0x1600_0099))

        let selected = targets(census(processes), aggregateGB: 60)

        #expect(selected.map(\.processGroupIDs) == [[300]])
        #expect(selected.first?.processCount == 63)
    }

    @Test
    func paneWithoutItsSessionRootFailsClosed() {
        // The login process is not a child of this cmux: the pane's shell
        // can't be identified, so nothing is signalled.
        #expect(targets(census(session(loginParent: 1) + runawayJob())).isEmpty)
    }

    @Test
    func paneWithoutATTYFailsClosed() {
        let snapshot = census(session() + runawayJob())

        #expect(targets(snapshot, descriptor: descriptor(ttyName: nil)).isEmpty)
    }

    @Test
    func commandSharingTheShellGroupIsNeverSignalled() {
        // A custom command without job control: everything stays in the
        // shell's group, which is protected.
        let processes = session() + runawayJob(includeLeader: false, workerParent: 200).map {
            process($0.pid, parent: 200, name: $0.name, group: 200, bytes: $0.memoryBytes)
        }

        #expect(targets(census(processes)).isEmpty)
    }

    @Test
    func paneBelowThresholdIsNeverSelected() {
        #expect(targets(census(session() + runawayJob(workerCount: 4)), aggregateGB: 4).isEmpty)
    }

    @Test
    func paneThatDoesNotDominateTheAggregateIsNeverSelected() {
        // 31 GB in this pane, but the rest of cmux holds far more: diffuse
        // pressure must not stop one pane's work.
        #expect(targets(census(session() + runawayJob()), aggregateGB: 80).isEmpty)
    }

    @Test
    func incompleteCensusNeverSelects() {
        let snapshot = census(session() + runawayJob(), enumerationIsComplete: false)

        #expect(targets(snapshot).isEmpty)
    }

    // MARK: Termination

    @Test
    func criticalAggregatePressureTerminatesTheRunawayGroupAndEscalatesWhenItSurvives() async {
        let recorder = SignalRecorder()
        let critical = aggregate(bytes: UInt64(60 * Self.gb))
        #expect(critical.severity == .critical)

        let selected = await evaluate(
            knownAggregate: critical,
            snapshots: SnapshotSequence([
                census(session() + runawayJob()),
                // The leader exited on SIGTERM; its orphaned workers did not.
                census(session() + runawayJob(includeLeader: false, workerParent: 1)),
            ]),
            recorder: recorder
        )

        #expect(selected.map(\.processGroupIDs) == [[300]])
        #expect(recorder.groups(for: SIGTERM) == [300])
        #expect(recorder.groups(for: SIGKILL) == [300])
    }

    @Test
    func groupThatExitsAfterSIGTERMIsNotForceKilled() async {
        let recorder = SignalRecorder()

        _ = await evaluate(
            knownAggregate: aggregate(bytes: UInt64(60 * Self.gb)),
            snapshots: SnapshotSequence([census(session() + runawayJob()), census(session())]),
            recorder: recorder
        )

        #expect(recorder.groups(for: SIGTERM) == [300])
        #expect(recorder.groups(for: SIGKILL).isEmpty)
    }

    @Test
    func cancelledGraceDeadlineSkipsEscalation() async {
        let recorder = SignalRecorder()

        _ = await evaluate(
            knownAggregate: aggregate(bytes: UInt64(60 * Self.gb)),
            snapshots: SnapshotSequence([census(session() + runawayJob())]),
            recorder: recorder,
            graceElapses: false
        )

        #expect(recorder.groups(for: SIGTERM) == [300])
        #expect(recorder.groups(for: SIGKILL).isEmpty)
    }

    @Test
    func warningOrIncompleteAggregateNeverSignals() async {
        let recorder = SignalRecorder()
        let warning = aggregate(bytes: UInt64(36 * Self.gb))
        #expect(warning.severity == .warning)
        let partial = aggregate(bytes: UInt64(60 * Self.gb), missingProcessCount: 3)
        #expect(partial.coverage == .lowerBound)
        #expect(partial.isActionable == false)

        for known in [warning, partial] {
            let selected = await evaluate(
                knownAggregate: known,
                snapshots: SnapshotSequence([census(session() + runawayJob())]),
                recorder: recorder
            )
            #expect(selected.isEmpty)
        }
        #expect(recorder.count == 0)
    }

    @Test
    func systemLaneResamplesTheAggregateBeforeActing() async {
        let recorder = SignalRecorder()

        let quietResample = await evaluate(
            knownAggregate: nil,
            resampledAggregate: aggregate(bytes: UInt64(36 * Self.gb)),
            snapshots: SnapshotSequence([census(session() + runawayJob())]),
            recorder: recorder
        )
        #expect(quietResample.isEmpty)
        #expect(recorder.count == 0)

        let criticalResample = await evaluate(
            knownAggregate: nil,
            resampledAggregate: aggregate(bytes: UInt64(60 * Self.gb)),
            snapshots: SnapshotSequence([census(session() + runawayJob()), census(session())]),
            recorder: recorder
        )
        #expect(criticalResample.map(\.processGroupIDs) == [[300]])
        #expect(recorder.groups(for: SIGTERM) == [300])
    }

    // MARK: Responder

    @MainActor
    @Test
    func responderSchedulesOneEvaluationAndSignalsThroughTheRegistry() async {
        let recorder = SignalRecorder()
        let snapshots = SnapshotSequence([census(session() + runawayJob()), census(session())])
        let paneDescriptor = descriptor()
        let responder = RunawayPaneTreeMemoryPressureResponder(
            paneProvider: { [paneDescriptor] },
            thresholdBytes: { Self.threshold },
            snapshotProvider: { snapshots.next() },
            aggregateProvider: { _ in
                Issue.record("a known aggregate must not be re-sampled")
                return MemoryPressureAggregatePolicy.default.evaluate(
                    sample: .unavailable(sampledAt: Date())
                )
            },
            signalProcessGroup: { recorder.record($0, $1) },
            waitForGraceDeadline: { true },
            app: Self.app,
            ttyDevice: Self.ttyDevice
        )
        let registry = MemoryPressureResponderRegistry()
        registry.register(responder)
        let snapshot = MemoryPressureSnapshot(
            severity: .critical,
            physicalFootprintBytes: nil,
            aggregateMemoryPressure: aggregate(bytes: UInt64(60 * Self.gb)),
            sampledAt: Date()
        )

        let first = registry.dispatch(snapshot, signal: .aggregate)
        let second = registry.dispatch(snapshot, signal: .system)
        await responder.pendingEvaluation?.value

        #expect(first.map(\.detail) == ["runaway-pane-evaluation"])
        #expect(second.map(\.detail) == ["runaway-pane-evaluation-in-flight"])
        #expect(recorder.groups(for: SIGTERM) == [300])
        #expect(responder.pendingEvaluation == nil)
    }

    @MainActor
    @Test
    func responderIgnoresNonCriticalAggregatePressure() {
        let responder = RunawayPaneTreeMemoryPressureResponder(
            paneProvider: {
                Issue.record("non-critical pressure must not read panes")
                return []
            },
            thresholdBytes: { Self.threshold },
            snapshotProvider: { CmuxTopProcessSnapshot(processes: [], sampledAt: Date(), includesProcessDetails: false) },
            aggregateProvider: { _ in
                MemoryPressureAggregatePolicy.default.evaluate(sample: .unavailable(sampledAt: Date()))
            },
            signalProcessGroup: { _, _ in Issue.record("must not signal") },
            waitForGraceDeadline: { true },
            app: Self.app,
            ttyDevice: Self.ttyDevice
        )
        let result = responder.shedMemory(
            for: MemoryPressureSnapshot(
                severity: .critical,
                physicalFootprintBytes: nil,
                aggregateMemoryPressure: aggregate(bytes: UInt64(36 * Self.gb)),
                sampledAt: Date()
            )
        )

        #expect(result.detail == "aggregate-not-critical")
        #expect(responder.pendingEvaluation == nil)
    }
}
