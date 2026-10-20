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
/// one pane's runaway `next dev` tree must be stopped under critical aggregate
/// pressure instead of taking the whole app down, without touching the
/// pane's login or shell.
@Suite
struct RunawayPaneTreeMemoryPressureResponderTests {
    private static let gb: Int64 = 1024 * 1024 * 1024
    private static let threshold: Int64 = 8 * gb
    private static let cmuxProcessGroupID = 1

    private let workspaceID = UUID()
    private let paneID = UUID()

    private var descriptor: PaneMemoryDescriptor {
        PaneMemoryDescriptor(
            workspaceId: workspaceID,
            panelId: paneID,
            workspaceTitle: "Workspace",
            paneTitle: "next dev",
            ttyName: nil,
            foregroundPID: 300
        )
    }

    private func process(
        _ pid: Int,
        parent: Int,
        name: String,
        group: Int,
        foregroundGroup: Int,
        bytes: Int64,
        surface: UUID? = nil
    ) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid, parentPID: parent, name: name, path: nil, ttyDevice: 0x1600_0003,
            cmuxWorkspaceID: surface == nil ? nil : workspaceID, cmuxSurfaceID: surface,
            cmuxAttributionReason: nil,
            processGroupID: group, terminalProcessGroupID: foregroundGroup, cpuPercent: 0,
            memoryBytes: bytes, memorySource: .physicalFootprint,
            residentBytes: bytes, residentMemorySource: .residentSize,
            virtualBytes: 0, threadCount: 1
        )
    }

    /// login(100) -> zsh(200) -> next dev(300) -> node workers, all in the
    /// foreground job group 300, like the reported fork storm.
    private func runawaySnapshot(
        workerCount: Int = 60,
        workerBytes: Int64 = 512 * 1024 * 1024,
        foregroundGroup: Int = 300,
        enumerationIsComplete: Bool = true
    ) -> CmuxTopProcessSnapshot {
        var processes = [
            process(100, parent: 1, name: "login", group: 100, foregroundGroup: foregroundGroup,
                    bytes: 4_000_000, surface: paneID),
            process(200, parent: 100, name: "zsh", group: 200, foregroundGroup: foregroundGroup,
                    bytes: 8_000_000, surface: paneID),
            process(300, parent: 200, name: "node", group: 300, foregroundGroup: foregroundGroup,
                    bytes: Self.gb, surface: paneID),
        ]
        for index in 0..<workerCount {
            processes.append(
                process(1_000 + index, parent: 300, name: "node", group: 300,
                        foregroundGroup: foregroundGroup, bytes: workerBytes)
            )
        }
        return CmuxTopProcessSnapshot(
            processes: processes,
            sampledAt: Date(),
            includesProcessDetails: false,
            enumerationIsComplete: enumerationIsComplete
        )
    }

    /// After SIGTERM only the login and shell remain.
    private func quietSnapshot() -> CmuxTopProcessSnapshot {
        CmuxTopProcessSnapshot(
            processes: [
                process(100, parent: 1, name: "login", group: 100, foregroundGroup: 200,
                        bytes: 4_000_000, surface: paneID),
                process(200, parent: 100, name: "zsh", group: 200, foregroundGroup: 200,
                        bytes: 8_000_000, surface: paneID),
            ],
            sampledAt: Date(),
            includesProcessDetails: false
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
        aggregate: MemoryPressureAggregateSnapshot,
        snapshots: SnapshotSequence,
        recorder: SignalRecorder,
        graceElapses: Bool = true
    ) async -> [RunawayPaneTreeTarget] {
        await RunawayPaneTreeMemoryPressureResponder.evaluate(
            descriptors: [descriptor],
            thresholdBytes: Self.threshold,
            knownAggregate: aggregate,
            sampledAt: Date(),
            snapshotProvider: { snapshots.next() },
            aggregateProvider: { _ in aggregate },
            signalProcessGroup: { recorder.record($0, $1) },
            waitForGraceDeadline: { graceElapses },
            currentProcessGroupID: Self.cmuxProcessGroupID
        )
    }

    @Test
    func selectsOnlyTheRunawayJobGroupNeverLoginOrShell() {
        let snapshot = runawaySnapshot()
        let targets = RunawayPaneTreeSelection.targets(
            descriptors: [descriptor],
            snapshot: snapshot,
            aggregateBytes: UInt64(32 * Self.gb),
            thresholdBytes: Self.threshold,
            currentProcessGroupID: Self.cmuxProcessGroupID
        )

        #expect(targets.count == 1)
        #expect(targets.first?.key == descriptor.key)
        #expect(targets.first?.processGroupIDs == [300])
        #expect(targets.first?.processCount == 63)
    }

    @Test
    func shellGroupStaysProtectedWhenTheRunawayIsABackgroundJob() {
        // `next dev &`: the shell owns the terminal foreground.
        let snapshot = runawaySnapshot(foregroundGroup: 200)
        let targets = RunawayPaneTreeSelection.targets(
            descriptors: [descriptor],
            snapshot: snapshot,
            aggregateBytes: UInt64(32 * Self.gb),
            thresholdBytes: Self.threshold,
            currentProcessGroupID: Self.cmuxProcessGroupID
        )

        #expect(targets.first?.processGroupIDs == [300])
    }

    @Test
    func paneBelowThresholdIsNeverSelected() {
        let snapshot = runawaySnapshot(workerCount: 4)
        let targets = RunawayPaneTreeSelection.targets(
            descriptors: [descriptor],
            snapshot: snapshot,
            aggregateBytes: UInt64(4 * Self.gb),
            thresholdBytes: Self.threshold,
            currentProcessGroupID: Self.cmuxProcessGroupID
        )

        #expect(targets.isEmpty)
    }

    @Test
    func paneThatDoesNotDominateTheAggregateIsNeverSelected() {
        // 31 GB in this pane, but the rest of cmux holds far more: diffuse
        // pressure must not stop one pane's work.
        let snapshot = runawaySnapshot()
        let targets = RunawayPaneTreeSelection.targets(
            descriptors: [descriptor],
            snapshot: snapshot,
            aggregateBytes: UInt64(80 * Self.gb),
            thresholdBytes: Self.threshold,
            currentProcessGroupID: Self.cmuxProcessGroupID
        )

        #expect(targets.isEmpty)
    }

    @Test
    func incompleteCensusNeverSelects() {
        let snapshot = runawaySnapshot(enumerationIsComplete: false)
        let targets = RunawayPaneTreeSelection.targets(
            descriptors: [descriptor],
            snapshot: snapshot,
            aggregateBytes: UInt64(32 * Self.gb),
            thresholdBytes: Self.threshold,
            currentProcessGroupID: Self.cmuxProcessGroupID
        )

        #expect(targets.isEmpty)
    }

    @Test
    func criticalAggregatePressureTerminatesTheRunawayGroupAndEscalatesWhenItSurvives() async {
        let recorder = SignalRecorder()
        let critical = aggregate(bytes: UInt64(60 * Self.gb))
        #expect(critical.severity == .critical)

        let targets = await evaluate(
            aggregate: critical,
            snapshots: SnapshotSequence([runawaySnapshot(), runawaySnapshot()]),
            recorder: recorder
        )

        #expect(targets.map(\.processGroupIDs) == [[300]])
        #expect(recorder.groups(for: SIGTERM) == [300])
        #expect(recorder.groups(for: SIGKILL) == [300])
    }

    @Test
    func groupThatExitsAfterSIGTERMIsNotForceKilled() async {
        let recorder = SignalRecorder()

        _ = await evaluate(
            aggregate: aggregate(bytes: UInt64(60 * Self.gb)),
            snapshots: SnapshotSequence([runawaySnapshot(), quietSnapshot()]),
            recorder: recorder
        )

        #expect(recorder.groups(for: SIGTERM) == [300])
        #expect(recorder.groups(for: SIGKILL).isEmpty)
    }

    @Test
    func cancelledGraceDeadlineSkipsEscalation() async {
        let recorder = SignalRecorder()

        _ = await evaluate(
            aggregate: aggregate(bytes: UInt64(60 * Self.gb)),
            snapshots: SnapshotSequence([runawaySnapshot()]),
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

        for snapshot in [warning, partial] {
            let targets = await evaluate(
                aggregate: snapshot,
                snapshots: SnapshotSequence([runawaySnapshot()]),
                recorder: recorder
            )
            #expect(targets.isEmpty)
        }
        #expect(recorder.count == 0)
    }

    @MainActor
    @Test
    func responderSchedulesOneEvaluationAndSignalsThroughTheRegistry() async {
        let recorder = SignalRecorder()
        let snapshots = SnapshotSequence([runawaySnapshot(), quietSnapshot()])
        let paneDescriptor = descriptor
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
            waitForGraceDeadline: { true }
        )
        let registry = MemoryPressureResponderRegistry()
        registry.register(responder)
        let critical = aggregate(bytes: UInt64(60 * Self.gb))
        let snapshot = MemoryPressureSnapshot(
            severity: .critical,
            physicalFootprintBytes: nil,
            aggregateMemoryPressure: critical,
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
            waitForGraceDeadline: { true }
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
