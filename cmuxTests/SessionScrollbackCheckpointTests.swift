import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Session scrollback checkpoint policy")
struct SessionScrollbackCheckpointPolicyTests {
    @Test func typingGateWaitsForQuietPeriod() {
        #expect(SessionScrollbackCheckpointPolicy.isTypingQuiet(secondsSinceTyping: nil))
        #expect(!SessionScrollbackCheckpointPolicy.isTypingQuiet(secondsSinceTyping: 0.2))
        #expect(!SessionScrollbackCheckpointPolicy.isTypingQuiet(
            secondsSinceTyping: SessionScrollbackCheckpointPolicy.typingQuietPeriod - 0.01
        ))
        #expect(SessionScrollbackCheckpointPolicy.isTypingQuiet(
            secondsSinceTyping: SessionScrollbackCheckpointPolicy.typingQuietPeriod
        ))
    }

    @Test func checkpointIsDueOnlyAfterInterval() {
        #expect(!SessionScrollbackCheckpointPolicy.isCheckpointDue(now: 100, lastCheckpointAt: 50, interval: 60))
        #expect(SessionScrollbackCheckpointPolicy.isCheckpointDue(now: 110, lastCheckpointAt: 50, interval: 60))
    }

    @Test func disabledWithSessionRestoreAndUnderAutomatedTests() {
        #expect(SessionScrollbackCheckpointPolicy.isEnabled(environment: [:]))
        #expect(!SessionScrollbackCheckpointPolicy.isEnabled(environment: ["CMUX_DISABLE_SESSION_RESTORE": "1"]))
        #expect(!SessionScrollbackCheckpointPolicy.isEnabled(environment: ["CMUX_UI_TEST_MODE": "1"]))
        #expect(!SessionScrollbackCheckpointPolicy.isEnabled(environment: ["XCTestConfigurationFilePath": "/tmp/x"]))
    }

    @Test func planCapturesOnlyEligibleTerminalsWithNewOutput() {
        let changed = UUID()
        let unchanged = UUID()
        let notRealized = UUID()
        let running = UUID()
        let plan = SessionScrollbackCheckpointPolicy.plan(
            candidates: [
                .init(panelId: changed, isEligible: true, hasPendingOutput: true),
                .init(panelId: unchanged, isEligible: true, hasPendingOutput: false),
                .init(panelId: notRealized, isEligible: true, hasPendingOutput: nil),
                .init(panelId: running, isEligible: false, hasPendingOutput: true),
            ],
            lastCapturedAt: [:]
        )

        #expect(plan.captures == [changed])
        #expect(plan.removals == [running])
        #expect(plan.livePanelIds == [changed, unchanged, notRealized, running])
    }

    @Test func planCapsCapturesAndPrefersLeastRecentlyCaptured() {
        let never = UUID()
        let old = UUID()
        let recent = UUID()
        let plan = SessionScrollbackCheckpointPolicy.plan(
            candidates: [recent, old, never].map {
                SessionScrollbackCheckpointPolicy.Candidate(panelId: $0, isEligible: true, hasPendingOutput: true)
            },
            lastCapturedAt: [old: 10, recent: 90],
            maxCaptures: 2
        )

        #expect(plan.captures == [never, old])
    }

    @Test func planSkipsTerminalsInBackoff() {
        let slow = UUID()
        let candidates = [
            SessionScrollbackCheckpointPolicy.Candidate(panelId: slow, isEligible: true, hasPendingOutput: true),
        ]
        #expect(SessionScrollbackCheckpointPolicy.plan(
            candidates: candidates, lastCapturedAt: [:], deferredUntil: [slow: 200], now: 100
        ).captures.isEmpty)
        #expect(SessionScrollbackCheckpointPolicy.plan(
            candidates: candidates, lastCapturedAt: [:], deferredUntil: [slow: 200], now: 200
        ).captures == [slow])
    }
}

@Suite("Terminal output activity for scrollback checkpoints")
struct TerminalScrollbackCheckpointActivityTests {
    @Test func outputMarksSurfacePendingUntilCaptureBegins() {
        let activity = TerminalScrollbackCheckpointActivity()
        let surface = UUID()
        #expect(activity.hasPendingOutput(surfaceID: surface) == nil)

        let flags = activity.register(surfaceID: surface)
        #expect(activity.hasPendingOutput(surfaceID: surface) == true)

        activity.clearRecentOutput(surfaceID: surface)
        #expect(activity.beginCapture(surfaceID: surface) == false)
        #expect(activity.hasPendingOutput(surfaceID: surface) == false)

        TerminalScrollbackCheckpointActivity.recordOutput(flags)
        #expect(activity.hasPendingOutput(surfaceID: surface) == true)
        #expect(activity.beginCapture(surfaceID: surface) == true)
    }

    @Test func releasingAnOlderRuntimeKeepsTheNewerRegistration() {
        let activity = TerminalScrollbackCheckpointActivity()
        let surface = UUID()
        let old = activity.register(surfaceID: surface)
        let current = activity.register(surfaceID: surface)
        _ = activity.beginCapture(surfaceID: surface)

        activity.unregister(surfaceID: surface, registration: old)
        #expect(activity.hasPendingOutput(surfaceID: surface) == false)

        activity.unregister(surfaceID: surface, registration: current)
        #expect(activity.hasPendingOutput(surfaceID: surface) == nil)
    }
}

/// Records discarded exports from any thread.
private final class DiscardLog: @unchecked Sendable {
    private let lock = NSLock()
    private var panelIds = Set<UUID>()

    func insert(_ panelId: UUID) {
        lock.lock()
        panelIds.insert(panelId)
        lock.unlock()
    }

    var discarded: Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return panelIds
    }
}

@MainActor
@Suite("Session scrollback checkpoint coordinator")
struct SessionScrollbackCheckpointCoordinatorTests {
    @MainActor
    private final class Harness {
        var uptime: TimeInterval = 1000
        var wallClock: TimeInterval = 5000
        var canCheckpoint = true
        var secondsSinceTyping: TimeInterval?
        var candidates: [SessionScrollbackCheckpointCoordinator.Candidate] = []
        var captureCounts: [UUID: Int] = [:]
        var batches: [SessionScrollbackCheckpointWriteBatch] = []
        var captureCost: TimeInterval = 0.001
        var onCapture: ((UUID) -> Void)?
        /// Runs before each deferred main-queue turn, standing in for the PTY read thread.
        var beforeMainTurn: (() -> Void)?
        let activity = TerminalScrollbackCheckpointActivity()
        var flags: [UUID: TerminalScrollbackOutputFlags] = [:]
        let discards = DiscardLog()

        func addTerminal(eligible: Bool = true, text: String? = "output") -> UUID {
            let panelId = UUID()
            flags[panelId] = activity.register(surfaceID: panelId)
            candidates.append(.init(
                panelId: panelId,
                surfaceId: panelId,
                isEligible: eligible,
                beginCapture: { [unowned self] in
                    self.captureCounts[panelId, default: 0] += 1
                    self.uptime += self.captureCost
                    self.onCapture?(panelId)
                    guard let text else { return nil }
                    return SessionScrollbackCheckpointExport(
                        finish: { text },
                        discard: { [discards] in discards.insert(panelId) }
                    )
                }
            ))
            return panelId
        }

        func output(_ panelId: UUID) {
            TerminalScrollbackCheckpointActivity.recordOutput(flags[panelId]!)
        }

        func makeCoordinator() -> SessionScrollbackCheckpointCoordinator {
            SessionScrollbackCheckpointCoordinator(
                environment: .init(
                    uptime: { [unowned self] in self.uptime },
                    wallClock: { [unowned self] in self.wallClock },
                    canCheckpoint: { [unowned self] in self.canCheckpoint },
                    secondsSinceTyping: { [unowned self] in self.secondsSinceTyping },
                    candidates: { [unowned self] in self.candidates },
                    scheduleNextCapture: { [unowned self] work in
                        self.beforeMainTurn?()
                        work()
                    },
                    persist: { [unowned self] in self.batches.append($0) }
                ),
                activity: activity
            )
        }

        func advanceToNextCheckpoint() {
            uptime += SessionScrollbackCheckpointPolicy.interval
            wallClock += SessionScrollbackCheckpointPolicy.interval
        }
    }

    @Test func waitsForIntervalAndTypingQuiet() {
        let harness = Harness()
        _ = harness.addTerminal()
        let coordinator = harness.makeCoordinator()

        #expect(!coordinator.tickIfDue())
        harness.advanceToNextCheckpoint()
        harness.secondsSinceTyping = 1
        #expect(!coordinator.tickIfDue())
        harness.canCheckpoint = false
        harness.secondsSinceTyping = nil
        #expect(!coordinator.tickIfDue())
        harness.canCheckpoint = true
        #expect(coordinator.tickIfDue())
        #expect(harness.batches.count == 1)
    }

    @Test func capturesOnlyTerminalsWithOutputSinceLastCheckpoint() throws {
        let harness = Harness()
        let first = harness.addTerminal(text: "one")
        let second = harness.addTerminal(text: "two")
        let coordinator = harness.makeCoordinator()

        harness.advanceToNextCheckpoint()
        #expect(coordinator.tickIfDue())
        let initial = try #require(harness.batches.last)
        #expect(Set(initial.captures.map(\.panelId)) == [first, second])
        #expect(initial.captures.allSatisfy { $0.capturedAt == harness.wallClock })

        harness.output(second)
        harness.advanceToNextCheckpoint()
        #expect(coordinator.tickIfDue())
        let next = try #require(harness.batches.last)
        #expect(next.captures.map(\.panelId) == [second])
        #expect(next.captures.first?.finish() == "two")
        #expect(harness.captureCounts[first] == 1)
        #expect(harness.captureCounts[second] == 2)
    }

    @Test func outputJustBeforeCaptureKeepsTerminalPendingForOneMoreCheckpoint() throws {
        let harness = Harness()
        let panel = harness.addTerminal()
        let coordinator = harness.makeCoordinator()
        // Bytes teed after the checkpoint planned the capture may still be
        // waiting for Ghostty's parser when the export runs.
        harness.beforeMainTurn = { harness.output(panel) }

        harness.advanceToNextCheckpoint()
        #expect(coordinator.tickIfDue())
        #expect(harness.captureCounts[panel] == 1)
        #expect(harness.activity.hasPendingOutput(surfaceID: panel) == true)

        harness.beforeMainTurn = nil
        harness.advanceToNextCheckpoint()
        #expect(coordinator.tickIfDue())
        #expect(harness.captureCounts[panel] == 2)
        #expect(harness.activity.hasPendingOutput(surfaceID: panel) == false)
    }

    @Test func ineligibleTerminalIsRemovedNotCaptured() throws {
        let harness = Harness()
        let running = harness.addTerminal(eligible: false)
        let coordinator = harness.makeCoordinator()

        harness.advanceToNextCheckpoint()
        #expect(coordinator.tickIfDue())
        let batch = try #require(harness.batches.last)
        #expect(batch.captures.isEmpty)
        #expect(batch.removals == [running])
        #expect(batch.livePanelIds == [running])
        #expect(harness.captureCounts[running] == nil)
    }

    @Test func typingDuringCheckpointLeavesRemainingTerminalsPending() throws {
        let harness = Harness()
        let panels = (0..<3).map { _ in harness.addTerminal() }
        harness.onCapture = { _ in harness.secondsSinceTyping = 0 }
        let coordinator = harness.makeCoordinator()

        harness.advanceToNextCheckpoint()
        #expect(coordinator.tickIfDue())
        let batch = try #require(harness.batches.last)
        #expect(batch.captures.count == 1)
        #expect(!coordinator.isCheckpointInFlight)
        let captured = try #require(batch.captures.first?.panelId)
        for panel in panels where panel != captured {
            #expect(harness.activity.hasPendingOutput(surfaceID: panel) == true)
        }
        #expect(harness.activity.hasPendingOutput(surfaceID: captured) == false)
    }

    @Test func mainThreadBudgetAndCaptureCapBoundOneCheckpoint() throws {
        let harness = Harness()
        _ = (0..<(SessionScrollbackCheckpointPolicy.maxCapturesPerCheckpoint + 2)).map { _ in
            harness.addTerminal()
        }
        let coordinator = harness.makeCoordinator()

        harness.advanceToNextCheckpoint()
        #expect(coordinator.tickIfDue())
        #expect(try #require(harness.batches.last).captures.count
            == SessionScrollbackCheckpointPolicy.maxCapturesPerCheckpoint)

        harness.captureCost = SessionScrollbackCheckpointPolicy.mainThreadCaptureBudget * 1.5
        harness.advanceToNextCheckpoint()
        #expect(coordinator.tickIfDue())
        #expect(try #require(harness.batches.last).captures.count == 1)
    }

    @Test func slowExportBacksOffThatTerminal() throws {
        let harness = Harness()
        let slow = harness.addTerminal()
        let coordinator = harness.makeCoordinator()
        harness.captureCost = SessionScrollbackCheckpointPolicy.mainThreadCaptureBudget * 2

        harness.advanceToNextCheckpoint()
        #expect(coordinator.tickIfDue())
        #expect(harness.captureCounts[slow] == 1)

        harness.captureCost = 0.001
        harness.output(slow)
        harness.advanceToNextCheckpoint()
        #expect(coordinator.tickIfDue())
        #expect(harness.captureCounts[slow] == 1)

        harness.uptime += SessionScrollbackCheckpointPolicy.slowCaptureBackoff
        #expect(coordinator.tickIfDue())
        #expect(harness.captureCounts[slow] == 2)
    }

    @Test func checkpointInterruptedByQuitOrRestoreDiscardsExportsSynchronously() throws {
        let harness = Harness()
        let panels = (0..<2).map { _ in harness.addTerminal() }
        harness.onCapture = { _ in harness.canCheckpoint = false }
        let coordinator = harness.makeCoordinator()

        harness.advanceToNextCheckpoint()
        #expect(coordinator.tickIfDue())
        #expect(!coordinator.isCheckpointInFlight)
        // Nothing reaches the utility queue, which may not run before exit.
        #expect(harness.batches.isEmpty)
        let exported = Set(panels.filter { harness.captureCounts[$0] == 1 })
        #expect(exported.count == 1)
        #expect(harness.discards.discarded == exported)
        for panel in panels {
            #expect(harness.activity.hasPendingOutput(surfaceID: panel) == true)
        }
    }

    @Test func failedExportStaysPendingAndBacksOff() throws {
        let harness = Harness()
        let panel = harness.addTerminal(text: nil)
        let coordinator = harness.makeCoordinator()

        harness.advanceToNextCheckpoint()
        #expect(coordinator.tickIfDue())
        #expect(try #require(harness.batches.last).captures.isEmpty)
        #expect(harness.activity.hasPendingOutput(surfaceID: panel) == true)

        harness.advanceToNextCheckpoint()
        #expect(coordinator.tickIfDue())
        #expect(harness.captureCounts[panel] == 1)
    }

    @Test func seedWritesRestoredScrollbackWithoutExport() throws {
        let harness = Harness()
        let panel = harness.addTerminal()
        let coordinator = harness.makeCoordinator()

        coordinator.seed([.init(panelId: panel, surfaceId: panel, scrollback: "restored\n")])

        let batch = try #require(harness.batches.last)
        #expect(batch.captures.map(\.panelId) == [panel])
        #expect(batch.captures.first?.finish() == "restored\n")
        #expect(batch.captures.first?.capturedAt == harness.wallClock)
        #expect(batch.livePanelIds == nil)
        #expect(harness.captureCounts[panel] == nil)
    }
}

@Suite("Session scrollback checkpoint store and restore")
struct SessionScrollbackCheckpointStoreTests {
    private func makeStore() -> SessionScrollbackCheckpointStore {
        SessionScrollbackCheckpointStore(
            primarySnapshotURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-scrollback-checkpoint-tests-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("session-com.cmuxterm.test.json", isDirectory: false)
        )
    }

    private func cleanUp(_ store: SessionScrollbackCheckpointStore) {
        try? FileManager.default.removeItem(at: store.directoryURL.deletingLastPathComponent())
    }

    private func capture(
        _ panelId: UUID,
        at capturedAt: TimeInterval,
        _ text: String?
    ) -> SessionScrollbackCheckpointCapture {
        SessionScrollbackCheckpointCapture(
            panelId: panelId,
            surfaceId: panelId,
            capturedAt: capturedAt,
            finish: { text }
        )
    }

    @Test func checkpointDirectorySitsNextToPrimarySnapshot() {
        let store = SessionScrollbackCheckpointStore(
            primarySnapshotURL: URL(fileURLWithPath: "/tmp/cmux/session-com.cmuxterm.app.json")
        )
        #expect(store.directoryURL.path == "/tmp/cmux/session-com.cmuxterm.app-scrollback")
    }

    @Test func writesTruncatesRemovesAndPrunes() throws {
        let store = makeStore()
        defer { cleanUp(store) }
        let kept = UUID()
        let cleared = UUID()
        let closed = UUID()
        let oversized = String(
            repeating: "x",
            count: SessionPersistencePolicy.maxScrollbackCharactersPerTerminal + 10
        )
        store.apply(.init(
            captures: [
                capture(kept, at: 10, oversized),
                capture(cleared, at: 10, "old"),
                capture(closed, at: 10, "closed"),
            ],
            removals: [],
            livePanelIds: [kept, cleared, closed]
        ))
        #expect(store.loadRecords(panelIds: [kept, cleared, closed]).count == 3)
        #expect(store.loadRecords(panelIds: [kept])[kept]?.scrollback.count
            == SessionPersistencePolicy.maxScrollbackCharactersPerTerminal)

        store.apply(.init(
            captures: [capture(cleared, at: 20, "  \n")],
            removals: [],
            livePanelIds: [kept, cleared]
        ))
        let records = store.loadRecords(panelIds: [kept, cleared, closed])
        #expect(Set(records.keys) == [kept])
    }

    @Test func seedBatchDoesNotPruneOtherCheckpoints() throws {
        let store = makeStore()
        defer { cleanUp(store) }
        let existing = UUID()
        let seeded = UUID()
        store.apply(.init(captures: [capture(existing, at: 10, "a")], removals: [], livePanelIds: [existing]))
        store.apply(.init(captures: [capture(seeded, at: 20, "b")], removals: [], livePanelIds: nil))

        #expect(Set(store.loadRecords(panelIds: [existing, seeded]).keys) == [existing, seeded])
    }

    @Test func failedCaptureOrWriteIsMarkedPendingAgain() throws {
        let activity = TerminalScrollbackCheckpointActivity()
        let failedExport = UUID()
        let failedWrite = UUID()
        for surface in [failedExport, failedWrite] {
            _ = activity.register(surfaceID: surface)
            _ = activity.beginCapture(surfaceID: surface)
        }
        // A regular file where the checkpoint directory should be makes every write fail.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-scrollback-checkpoint-blocker-\(UUID().uuidString)")
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let store = SessionScrollbackCheckpointStore(directoryURL: blocker)

        store.applyMarkingFailuresPending(
            .init(
                captures: [capture(failedExport, at: 1, nil), capture(failedWrite, at: 1, "text")],
                removals: [],
                livePanelIds: nil
            ),
            activity: activity
        )

        #expect(activity.hasPendingOutput(surfaceID: failedExport) == true)
        #expect(activity.hasPendingOutput(surfaceID: failedWrite) == true)
    }

    @Test func crashRestoreAfterAutosaveFillsScrollbackFromCheckpoint() throws {
        let store = makeStore()
        defer { cleanUp(store) }
        let panel = UUID()
        let dockPanel = UUID()
        store.apply(.init(
            captures: [capture(panel, at: 100, "checkpointed\n"), capture(dockPanel, at: 100, "dock\n")],
            removals: [],
            livePanelIds: [panel, dockPanel]
        ))

        // The production crash path: the last primary save is an 8 s autosave,
        // newer than the checkpoint, with no scrollback and no capture marker.
        let merged = store.merging(into: Self.snapshot(
            createdAt: 200,
            scrollbackCapturedAt: nil,
            panels: [(panel, nil)],
            dockPanels: [(dockPanel, nil)]
        ))

        let workspace = try #require(merged.windows.first?.tabManager.workspaces.first)
        #expect(workspace.panels.first?.terminal?.scrollback == "checkpointed\n")
        #expect(merged.windows.first?.dock?.panels.first?.terminal?.scrollback == "dock\n")
    }

    @Test func newerScrollbackSaveWinsEvenWhenItOmittedScrollback() throws {
        let store = makeStore()
        defer { cleanUp(store) }
        let omitted = UUID()
        let kept = UUID()
        store.apply(.init(
            captures: [capture(omitted, at: 100, "stale\n"), capture(kept, at: 100, "stale\n")],
            removals: [],
            livePanelIds: [omitted, kept]
        ))

        // A power-off save after the checkpoint deliberately left one terminal empty.
        let merged = store.merging(into: Self.snapshot(
            createdAt: 150,
            scrollbackCapturedAt: 150,
            panels: [(omitted, nil), (kept, "quit\n")]
        ))

        let panels = try #require(merged.windows.first?.tabManager.workspaces.first?.panels)
        #expect(panels[0].terminal?.scrollback == nil)
        #expect(panels[1].terminal?.scrollback == "quit\n")
    }

    @Test func restorePicksTheNewestScrollback() {
        let checkpoint = SessionScrollbackCheckpointRecord(
            version: SessionScrollbackCheckpointRecord.currentVersion,
            panelId: UUID(),
            capturedAt: 100,
            scrollback: "checkpoint"
        )
        func resolve(_ scrollback: String?, createdAt: TimeInterval, capturedAt: TimeInterval?) -> String? {
            SessionScrollbackCheckpointMerge.resolvedScrollback(
                snapshotScrollback: scrollback,
                snapshotCreatedAt: createdAt,
                snapshotScrollbackCapturedAt: capturedAt,
                checkpoint: checkpoint
            )
        }
        // Scrollback-bearing saves: newest wins, including a deliberate nil.
        #expect(resolve("quit", createdAt: 200, capturedAt: 200) == "quit")
        #expect(resolve(nil, createdAt: 200, capturedAt: 200) == nil)
        #expect(resolve("quit", createdAt: 50, capturedAt: 50) == "checkpoint")
        // Autosave (no marker, no scrollback): the checkpoint wins.
        #expect(resolve(nil, createdAt: 200, capturedAt: nil) == "checkpoint")
        // Legacy snapshot with its own newer scrollback keeps it.
        #expect(resolve("legacy", createdAt: 200, capturedAt: nil) == "legacy")
        #expect(SessionScrollbackCheckpointMerge.resolvedScrollback(
            snapshotScrollback: "quit",
            snapshotCreatedAt: 200,
            snapshotScrollbackCapturedAt: 200,
            checkpoint: nil
        ) == "quit")
    }

    @Test func laterCheckpointReplacesEarlierOne() throws {
        let store = makeStore()
        defer { cleanUp(store) }
        let panel = UUID()
        store.apply(.init(captures: [capture(panel, at: 100, "first\n")], removals: [], livePanelIds: [panel]))
        store.apply(.init(captures: [capture(panel, at: 160, "second\n")], removals: [], livePanelIds: [panel]))

        let merged = store.merging(into: Self.snapshot(
            createdAt: 170,
            scrollbackCapturedAt: nil,
            panels: [(panel, nil)]
        ))
        #expect(merged.windows.first?.tabManager.workspaces.first?.panels.first?.terminal?.scrollback
            == "second\n")
    }

    @Test func ignoresRecordsFiledUnderAnotherPanel() throws {
        let store = makeStore()
        defer { cleanUp(store) }
        let panel = UUID()
        let record = SessionScrollbackCheckpointRecord(
            version: SessionScrollbackCheckpointRecord.currentVersion,
            panelId: UUID(),
            capturedAt: 1,
            scrollback: "wrong"
        )
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: store.fileURL(panelId: panel))

        #expect(store.loadRecords(panelIds: [panel]).isEmpty)
    }

    @Test func scrollbackCaptureMarkerRoundTripsAndDefaultsToNil() throws {
        let marked = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [],
            scrollbackCapturedAt: 10
        )
        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: JSONEncoder().encode(marked))
        #expect(decoded.scrollbackCapturedAt == 10)

        let legacy = Data(#"{"version":1,"createdAt":5,"windows":[]}"#.utf8)
        #expect(try JSONDecoder().decode(AppSessionSnapshot.self, from: legacy).scrollbackCapturedAt == nil)
    }

    private static func snapshot(
        createdAt: TimeInterval,
        scrollbackCapturedAt: TimeInterval?,
        panels: [(UUID, String?)],
        dockPanels: [(UUID, String?)] = []
    ) -> AppSessionSnapshot {
        let panelSnapshots = panels.map { terminalPanel(id: $0.0, scrollback: $0.1) }
        let dock = dockPanels.isEmpty ? nil : SessionSplitContainerSnapshot(
            focusedPanelId: dockPanels.first?.0,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: dockPanels.map(\.0), selectedPanelId: nil)),
            panels: dockPanels.map { terminalPanel(id: $0.0, scrollback: $0.1) }
        )
        return AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: createdAt,
            windows: [
                SessionWindowSnapshot(
                    frame: nil,
                    display: nil,
                    tabManager: SessionTabManagerSnapshot(
                        selectedWorkspaceIndex: 0,
                        workspaces: [
                            SessionWorkspaceSnapshot(
                                processTitle: "Terminal",
                                customTitle: nil,
                                customColor: nil,
                                isPinned: false,
                                currentDirectory: "/tmp",
                                focusedPanelId: panels.first?.0,
                                layout: .pane(SessionPaneLayoutSnapshot(
                                    panelIds: panels.map(\.0),
                                    selectedPanelId: panels.first?.0
                                )),
                                panels: panelSnapshots,
                                statusEntries: [],
                                logEntries: [],
                                progress: nil,
                                gitBranch: nil
                            ),
                        ]
                    ),
                    sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil),
                    dock: dock
                ),
            ],
            scrollbackCapturedAt: scrollbackCapturedAt
        )
    }

    private static func terminalPanel(id: UUID, scrollback: String?) -> SessionPanelSnapshot {
        SessionPanelSnapshot(
            id: id,
            type: .terminal,
            title: "Terminal",
            customTitle: nil,
            directory: "/tmp",
            isPinned: false,
            isManuallyUnread: false,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(workingDirectory: "/tmp", scrollback: scrollback),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil
        )
    }
}
