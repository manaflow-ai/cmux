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
/// the pane's login or shell. Selection policy is covered by
/// `RunawaySessionSelectorTests` in CmuxMemoryPressure.
@Suite
struct RunawayPaneTreeMemoryPressureResponderTests {
    private static let gb: Int64 = 1024 * 1024 * 1024
    private static let threshold: Int64 = 8 * gb
    private static let paneTTY: Int64 = 0x1600_0003
    private static let paneTTYName = "/dev/ttys003"
    private static let appPID = 50
    private static let ttyDevice: RunawayPaneTreeMemoryPressureResponder.TTYDeviceResolver = {
        $0 == paneTTYName ? paneTTY : nil
    }
    private static let selector = RunawaySessionSelector(
        appProcessID: appPID,
        appProcessGroupID: appPID,
        thresholdBytes: threshold
    )

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
        name: String = "node",
        group: Int,
        bytes: Int64
    ) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid, parentPID: parent, name: name, path: nil, ttyDevice: Self.paneTTY,
            cmuxWorkspaceID: nil, cmuxSurfaceID: nil, cmuxAttributionReason: nil,
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

    /// cmux(50) -> login(100) -> zsh(200).
    private func session() -> [CmuxTopProcessInfo] {
        [
            process(100, parent: Self.appPID, name: "login", group: 100, bytes: 4_000_000),
            process(200, parent: 100, name: "zsh", group: 200, bytes: 8_000_000),
        ]
    }

    /// `next dev`(300) and 60 node workers in job group 300 (31 GB).
    /// Without the leader, the workers were reparented to launchd.
    private func runawayJob(includeLeader: Bool = true) -> [CmuxTopProcessInfo] {
        var processes: [CmuxTopProcessInfo] = []
        if includeLeader {
            processes.append(process(300, parent: 200, group: 300, bytes: Self.gb))
        }
        for index in 0..<60 {
            processes.append(
                process(1_000 + index, parent: includeLeader ? 300 : 1, group: 300, bytes: Self.gb / 2)
            )
        }
        return processes
    }

    private func aggregate(
        bytes: UInt64,
        missingProcessCount: Int = 0
    ) -> MemoryPressureAggregateSnapshot {
        // A missing record only makes a descendant-tree sample a lower bound.
        let sample = MemoryPressureAggregateSample(
            source: missingProcessCount > 0 ? .descendantProcessTree : .coalition,
            aggregateBytes: bytes,
            physicalMemoryBytes: 64 * 1024 * 1024 * 1024,
            availableMemoryBytes: 32 * 1024 * 1024 * 1024,
            processCount: 64,
            missingProcessCount: missingProcessCount,
            missingReason: missingProcessCount > 0 ? .processExitRace : nil,
            sampledAt: Date()
        )
        return MemoryPressureAggregatePolicy.default.evaluate(sample: sample)
    }

    private var critical: MemoryPressureAggregateSnapshot { aggregate(bytes: UInt64(60 * Self.gb)) }

    private func evaluate(
        knownAggregate: MemoryPressureAggregateSnapshot?,
        resampledAggregate: MemoryPressureAggregateSnapshot? = nil,
        descriptor: PaneMemoryDescriptor? = nil,
        snapshots: SnapshotSequence,
        recorder: SignalRecorder,
        graceElapses: Bool = true
    ) async -> [RunawayPaneTreeTarget] {
        let resampled = resampledAggregate ?? MemoryPressureAggregatePolicy.default.evaluate(
            sample: .unavailable(sampledAt: Date())
        )
        return await RunawayPaneTreeMemoryPressureResponder.evaluate(
            descriptors: [descriptor ?? self.descriptor()],
            selector: Self.selector,
            knownAggregate: knownAggregate,
            sampledAt: Date(),
            snapshotProvider: { snapshots.next() },
            aggregateProvider: { _ in resampled },
            signalProcessGroup: { recorder.record($0, $1) },
            waitForGraceDeadline: { graceElapses },
            ttyDevice: Self.ttyDevice
        )
    }

    private func makeResponder(
        isEnabled: Bool = true,
        snapshots: SnapshotSequence,
        recorder: SignalRecorder
    ) -> RunawayPaneTreeMemoryPressureResponder {
        let paneDescriptor = descriptor()
        return RunawayPaneTreeMemoryPressureResponder(
            isEnabled: { isEnabled },
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
            ttyDevice: Self.ttyDevice,
            appProcessID: Self.appPID,
            appProcessGroupID: Self.appPID
        )
    }

    @Test
    func criticalPressureTerminatesTheRunawayGroupAndEscalatesOnOrphanedSurvivors() async {
        let recorder = SignalRecorder()
        #expect(critical.severity == .critical)

        let targets = await evaluate(
            knownAggregate: critical,
            snapshots: SnapshotSequence([
                census(session() + runawayJob()),
                // The leader exited on SIGTERM; its reparented workers did not.
                census(session() + runawayJob(includeLeader: false)),
            ]),
            recorder: recorder
        )

        #expect(targets.map(\.selection.processGroupIDs) == [[300]])
        #expect(targets.first?.key == descriptor().key)
        #expect(recorder.groups(for: SIGTERM) == [300])
        #expect(recorder.groups(for: SIGKILL) == [300])
    }

    @Test
    func groupThatExitsAfterSIGTERMIsNotForceKilled() async {
        let recorder = SignalRecorder()

        _ = await evaluate(
            knownAggregate: critical,
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
            knownAggregate: critical,
            snapshots: SnapshotSequence([census(session() + runawayJob())]),
            recorder: recorder,
            graceElapses: false
        )

        #expect(recorder.groups(for: SIGTERM) == [300])
        #expect(recorder.groups(for: SIGKILL).isEmpty)
    }

    @Test
    func incompleteFollowUpCensusSkipsEscalation() async {
        let recorder = SignalRecorder()

        _ = await evaluate(
            knownAggregate: critical,
            snapshots: SnapshotSequence([
                census(session() + runawayJob()),
                census(session() + runawayJob(), enumerationIsComplete: false),
            ]),
            recorder: recorder
        )

        #expect(recorder.groups(for: SIGTERM) == [300])
        #expect(recorder.groups(for: SIGKILL).isEmpty)
    }

    @Test
    func incompleteCensusOrMissingTTYNeverSignals() async {
        let recorder = SignalRecorder()

        let incomplete = await evaluate(
            knownAggregate: critical,
            snapshots: SnapshotSequence([census(session() + runawayJob(), enumerationIsComplete: false)]),
            recorder: recorder
        )
        let noTTY = await evaluate(
            knownAggregate: critical,
            descriptor: descriptor(ttyName: nil),
            snapshots: SnapshotSequence([census(session() + runawayJob())]),
            recorder: recorder
        )

        #expect(incomplete.isEmpty)
        #expect(noTTY.isEmpty)
        #expect(recorder.count == 0)
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
            let targets = await evaluate(
                knownAggregate: known,
                snapshots: SnapshotSequence([census(session() + runawayJob())]),
                recorder: recorder
            )
            #expect(targets.isEmpty)
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
            resampledAggregate: critical,
            snapshots: SnapshotSequence([census(session() + runawayJob()), census(session())]),
            recorder: recorder
        )
        #expect(criticalResample.map(\.selection.processGroupIDs) == [[300]])
        #expect(recorder.groups(for: SIGTERM) == [300])
    }

    @MainActor
    @Test
    func responderSchedulesOneEvaluationAndSignalsThroughTheRegistry() async {
        let recorder = SignalRecorder()
        let responder = makeResponder(
            snapshots: SnapshotSequence([census(session() + runawayJob()), census(session())]),
            recorder: recorder
        )
        let registry = MemoryPressureResponderRegistry()
        registry.register(responder)
        let snapshot = MemoryPressureSnapshot(
            severity: .critical,
            physicalFootprintBytes: nil,
            aggregateMemoryPressure: critical,
            sampledAt: Date()
        )

        let first = registry.dispatch(snapshot, signal: .aggregate)
        let second = registry.dispatch(snapshot, signal: .system)
        await responder.evaluationTask?.value

        #expect(first.map(\.detail) == ["runaway-pane-evaluation"])
        #expect(second.map(\.detail) == ["runaway-pane-evaluation-in-flight"])
        #expect(recorder.groups(for: SIGTERM) == [300])
        #expect(responder.evaluationTask == nil)
    }

    @MainActor
    @Test
    func disabledGuardrailNeverEvaluates() {
        let recorder = SignalRecorder()
        let responder = makeResponder(
            isEnabled: false,
            snapshots: SnapshotSequence([census(session() + runawayJob())]),
            recorder: recorder
        )

        let result = responder.shedMemory(
            for: MemoryPressureSnapshot(
                severity: .critical,
                physicalFootprintBytes: nil,
                aggregateMemoryPressure: critical,
                sampledAt: Date()
            )
        )

        #expect(result.detail == "runaway-guardrail-disabled")
        #expect(responder.evaluationTask == nil)
        #expect(recorder.count == 0)
    }

    @MainActor
    @Test
    func responderIgnoresNonCriticalAggregatePressure() {
        let recorder = SignalRecorder()
        let responder = makeResponder(
            snapshots: SnapshotSequence([census(session() + runawayJob())]),
            recorder: recorder
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
        #expect(responder.evaluationTask == nil)
    }
}
