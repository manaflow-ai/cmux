import Darwin
import Foundation
import Testing
import CmuxMemoryPressure

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class WarningSignalRecorder: @unchecked Sendable {
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
}

private final class WarningSnapshotSource: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: CmuxTopProcessSnapshot

    init(_ snapshot: CmuxTopProcessSnapshot) {
        self.snapshot = snapshot
    }

    func set(_ snapshot: CmuxTopProcessSnapshot) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }

    func current() -> CmuxTopProcessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}

private let warningPaneTTY: Int64 = 0x1600_0003
private let warningPaneTTYName = "/dev/ttys003"

/// https://github.com/manaflow-ai/cmux/issues/22273: when a terminal's
/// process tree runs away, cmux names that terminal (workspace and tab, top
/// command, process count, memory) and offers to stop its tree, before macOS
/// takes cmux down.
@MainActor
@Suite
struct RunawayPaneWarningCenterTests {
    private static let gb: Int64 = 1024 * 1024 * 1024
    private static let appPID = 50

    private let workspaceID = UUID()
    private let paneID = UUID()

    private var descriptor: PaneMemoryDescriptor {
        PaneMemoryDescriptor(
            workspaceId: workspaceID,
            panelId: paneID,
            workspaceTitle: "my-app",
            paneTitle: "dev server",
            ttyName: warningPaneTTYName,
            foregroundPID: 300
        )
    }

    private func process(_ pid: Int, parent: Int, name: String = "node", group: Int, bytes: Int64) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid, parentPID: parent, name: name, path: nil, ttyDevice: warningPaneTTY,
            cmuxWorkspaceID: nil, cmuxSurfaceID: nil, cmuxAttributionReason: nil,
            processGroupID: group, terminalProcessGroupID: 300, cpuPercent: 0,
            memoryBytes: bytes, memorySource: .physicalFootprint,
            residentBytes: bytes, residentMemorySource: .residentSize,
            virtualBytes: 0, threadCount: 1
        )
    }

    /// cmux(50) -> login(100) -> zsh(200) -> `next dev`(300) with `workers`
    /// node workers in job group 300.
    private func census(
        workers: Int,
        workerBytes: Int64 = 1_000_000,
        jobGroup: Int = 300
    ) -> CmuxTopProcessSnapshot {
        var processes = [
            process(100, parent: Self.appPID, name: "login", group: 100, bytes: 4_000_000),
            process(200, parent: 100, name: "zsh", group: 200, bytes: 8_000_000),
            process(300, parent: 200, group: jobGroup, bytes: 200_000_000),
        ]
        for index in 0..<workers {
            processes.append(process(1_000 + index, parent: 300, group: jobGroup, bytes: workerBytes))
        }
        return CmuxTopProcessSnapshot(
            processes: processes,
            sampledAt: Date(),
            includesProcessDetails: false,
            includesCMUXScope: false
        )
    }

    private func makeCenter(
        source: WarningSnapshotSource,
        freshSource: WarningSnapshotSource? = nil,
        recorder: WarningSignalRecorder
    ) -> RunawayPaneWarningCenter {
        let snapshot: @Sendable () async -> CmuxTopProcessSnapshot = { source.current() }
        let freshSource = freshSource ?? source
        let freshSnapshot: @Sendable () async -> CmuxTopProcessSnapshot = { freshSource.current() }
        let center = RunawayPaneWarningCenter(
            thresholdBytes: { 8 * Self.gb },
            processCountThreshold: 1_000,
            snapshotProvider: snapshot,
            argumentsProvider: { process in
                process.pid == 300 ? ["node", "/app/node_modules/.bin/next", "dev"] : nil
            },
            terminator: RunawayPaneTreeTerminator(
                snapshotProvider: freshSnapshot,
                signalProcessGroup: { recorder.record($0, $1) },
                waitForGraceDeadline: { true }
            ),
            ttyDevice: { $0 == warningPaneTTYName ? warningPaneTTY : nil },
            appProcessID: Self.appPID,
            appProcessGroupID: Self.appPID
        )
        let paneDescriptor = descriptor
        center.paneProvider = { [paneDescriptor] }
        return center
    }

    private func evaluate(_ center: RunawayPaneWarningCenter) async {
        center.evaluate()
        await center.evaluationTask?.value
    }

    @Test
    func forkStormNamesTheTerminalCommandProcessCountAndMemoryOnce() async {
        let source = WarningSnapshotSource(census(workers: 10))
        let center = makeCenter(source: source, recorder: WarningSignalRecorder())
        var notified: [RunawayPaneWarning] = []
        center.onNewWarning = { notified.append($0) }

        await evaluate(center)
        #expect(center.warnings.isEmpty)

        source.set(census(workers: 3_571))
        await evaluate(center)

        let warning = center.warnings.first
        #expect(center.warnings.count == 1)
        #expect(warning?.workspaceId == workspaceID)
        #expect(warning?.panelId == paneID)
        #expect(warning?.workspaceTitle == "my-app")
        #expect(warning?.paneTitle == "dev server")
        #expect(warning?.command == "next dev")
        #expect(warning?.processCount == 3_574)
        #expect(warning?.memoryBytes == 212_000_000 + 3_571 * 1_000_000)
        #expect(warning?.canStop == true)
        #expect(notified.map(\.key) == [descriptor.key])

        // Still running away: the banner stays, the notification does not repeat.
        await evaluate(center)
        #expect(center.warnings.count == 1)
        #expect(notified.count == 1)
    }

    @Test
    func stopProcessTreeSignalsEveryJobButNotLoginOrShell() async {
        let source = WarningSnapshotSource(census(workers: 1_200))
        let recorder = WarningSignalRecorder()
        let center = makeCenter(source: source, recorder: recorder)
        await evaluate(center)
        guard let warning = center.warnings.first else {
            Issue.record("expected a runaway warning")
            return
        }

        center.stopProcessTree(warning)
        await center.stopTasks[warning.key]?.value

        #expect(center.warnings.isEmpty)
        #expect(recorder.groups(for: SIGTERM) == [300])
        #expect(recorder.groups(for: SIGKILL) == [300], "the survivors were still running after the grace deadline")
        #expect(center.stopTasks.isEmpty)
    }

    @Test
    func stopSelectsGroupsFromAFreshCensusNotTheCachedOne() async {
        // The cached census still lists job group 300; by the time the user
        // clicks Stop, the job has exited and a new job owns group 400.
        let recorder = WarningSignalRecorder()
        let fresh = WarningSnapshotSource(census(workers: 1_200, jobGroup: 400))
        let center = makeCenter(
            source: WarningSnapshotSource(census(workers: 1_200)),
            freshSource: fresh,
            recorder: recorder
        )
        await evaluate(center)
        guard let warning = center.warnings.first else {
            Issue.record("expected a runaway warning")
            return
        }

        center.stopProcessTree(warning)
        await center.stopTasks[warning.key]?.value

        #expect(recorder.groups(for: SIGTERM) == [400])
    }

    @Test
    func runawayInTheShellGroupCannotBeStoppedAndStaysVisible() async {
        // `exec next dev` or a command without job control: everything is in
        // the shell's protected group, so Stop has nothing it may signal.
        let recorder = WarningSignalRecorder()
        let center = makeCenter(
            source: WarningSnapshotSource(census(workers: 1_200, jobGroup: 200)),
            recorder: recorder
        )
        await evaluate(center)
        guard let warning = center.warnings.first else {
            Issue.record("expected a runaway warning")
            return
        }
        #expect(warning.canStop == false)

        center.stopProcessTree(warning)
        await center.stopTasks[warning.key]?.value

        #expect(recorder.groups(for: SIGTERM).isEmpty)
        #expect(center.warnings.map(\.key) == [warning.key], "a stop that signalled nothing must not hide the warning")
        #expect(center.warnings.first?.canStop == false)
    }

    @Test
    func dismissedWarningStaysHiddenUntilTheTerminalRecovers() async {
        let source = WarningSnapshotSource(census(workers: 1_200))
        let center = makeCenter(source: source, recorder: WarningSignalRecorder())
        var notified = 0
        center.onNewWarning = { _ in notified += 1 }
        await evaluate(center)
        guard let warning = center.warnings.first else {
            Issue.record("expected a runaway warning")
            return
        }

        center.dismiss(warning)
        await evaluate(center)
        #expect(center.warnings.isEmpty)

        source.set(census(workers: 10))
        await evaluate(center)
        source.set(census(workers: 1_200))
        await evaluate(center)
        #expect(center.warnings.count == 1)
        #expect(notified == 2)
    }
}
