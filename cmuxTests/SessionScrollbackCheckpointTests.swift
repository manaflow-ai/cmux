import CmuxFoundation
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
}

@Suite("Terminal output activity for scrollback checkpoints")
struct TerminalScrollbackCheckpointActivityTests {
    @Test func outputMarksSurfacePendingUntilCaptureBegins() {
        let activity = TerminalScrollbackCheckpointActivity()
        let surface = UUID()
        #expect(activity.hasPendingOutput(surfaceID: surface) == nil)

        let gate = activity.register(surfaceID: surface)
        #expect(activity.hasPendingOutput(surfaceID: surface) == true)

        activity.beginCapture(surfaceID: surface)
        #expect(activity.hasPendingOutput(surfaceID: surface) == false)

        TerminalScrollbackCheckpointActivity.recordOutput(gate)
        #expect(activity.hasPendingOutput(surfaceID: surface) == true)
    }

    @Test func releasingAnOlderRuntimeKeepsTheNewerRegistration() {
        let activity = TerminalScrollbackCheckpointActivity()
        let surface = UUID()
        let old = activity.register(surfaceID: surface)
        let current = activity.register(surfaceID: surface)
        activity.beginCapture(surfaceID: surface)

        activity.unregister(surfaceID: surface, gate: old)
        #expect(activity.hasPendingOutput(surfaceID: surface) == false)

        activity.unregister(surfaceID: surface, gate: current)
        #expect(activity.hasPendingOutput(surfaceID: surface) == nil)
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
        let activity = TerminalScrollbackCheckpointActivity()
        var gates: [UUID: AtomicBooleanGate] = [:]

        func addTerminal(eligible: Bool = true, text: String? = "output") -> UUID {
            let panelId = UUID()
            gates[panelId] = activity.register(surfaceID: panelId)
            candidates.append(.init(
                panelId: panelId,
                surfaceId: panelId,
                isEligible: eligible,
                capture: { [unowned self] in
                    self.captureCounts[panelId, default: 0] += 1
                    self.uptime += self.captureCost
                    self.onCapture?(panelId)
                    return text
                }
            ))
            return panelId
        }

        func makeCoordinator() -> SessionScrollbackCheckpointCoordinator {
            SessionScrollbackCheckpointCoordinator(
                environment: .init(
                    uptime: { [unowned self] in self.uptime },
                    wallClock: { [unowned self] in self.wallClock },
                    canCheckpoint: { [unowned self] in self.canCheckpoint },
                    secondsSinceTyping: { [unowned self] in self.secondsSinceTyping },
                    candidates: { [unowned self] in self.candidates },
                    scheduleNextCapture: { $0() },
                    persist: { [unowned self] in self.batches.append($0) }
                ),
                activity: activity
            )
        }
    }

    @Test func waitsForIntervalAndTypingQuiet() {
        let harness = Harness()
        _ = harness.addTerminal()
        let coordinator = harness.makeCoordinator()

        #expect(!coordinator.tickIfDue())
        harness.uptime += SessionScrollbackCheckpointPolicy.interval
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

        harness.uptime += SessionScrollbackCheckpointPolicy.interval
        #expect(coordinator.tickIfDue())
        let initial = try #require(harness.batches.last)
        #expect(Set(initial.captures.map(\.panelId)) == [first, second])
        #expect(initial.captures.allSatisfy { $0.capturedAt == harness.wallClock })

        TerminalScrollbackCheckpointActivity.recordOutput(try #require(harness.gates[second]))
        harness.uptime += SessionScrollbackCheckpointPolicy.interval
        #expect(coordinator.tickIfDue())
        let next = try #require(harness.batches.last)
        #expect(next.captures.map(\.panelId) == [second])
        #expect(next.captures.first?.scrollback == "two")
        #expect(harness.captureCounts[first] == 1)
        #expect(harness.captureCounts[second] == 2)
    }

    @Test func ineligibleTerminalIsRemovedNotCaptured() throws {
        let harness = Harness()
        let running = harness.addTerminal(eligible: false)
        let coordinator = harness.makeCoordinator()

        harness.uptime += SessionScrollbackCheckpointPolicy.interval
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

        harness.uptime += SessionScrollbackCheckpointPolicy.interval
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

        harness.uptime += SessionScrollbackCheckpointPolicy.interval
        #expect(coordinator.tickIfDue())
        #expect(try #require(harness.batches.last).captures.count
            == SessionScrollbackCheckpointPolicy.maxCapturesPerCheckpoint)

        harness.captureCost = SessionScrollbackCheckpointPolicy.mainThreadCaptureBudget
        harness.uptime += SessionScrollbackCheckpointPolicy.interval
        #expect(coordinator.tickIfDue())
        #expect(try #require(harness.batches.last).captures.count == 1)
    }

    @Test func checkpointInterruptedByQuitOrRestoreKeepsCapturesPending() {
        let harness = Harness()
        let panels = (0..<2).map { _ in harness.addTerminal() }
        harness.onCapture = { _ in harness.canCheckpoint = false }
        let coordinator = harness.makeCoordinator()

        harness.uptime += SessionScrollbackCheckpointPolicy.interval
        #expect(coordinator.tickIfDue())
        #expect(harness.batches.isEmpty)
        #expect(!coordinator.isCheckpointInFlight)
        for panel in panels {
            #expect(harness.activity.hasPendingOutput(surfaceID: panel) == true)
        }
    }

    @Test func failedCaptureStaysPending() throws {
        let harness = Harness()
        let panel = harness.addTerminal(text: nil)
        let coordinator = harness.makeCoordinator()

        harness.uptime += SessionScrollbackCheckpointPolicy.interval
        #expect(coordinator.tickIfDue())
        #expect(try #require(harness.batches.last).captures.isEmpty)
        #expect(harness.activity.hasPendingOutput(surfaceID: panel) == true)
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
                .init(panelId: kept, capturedAt: 10, scrollback: oversized),
                .init(panelId: cleared, capturedAt: 10, scrollback: "old"),
                .init(panelId: closed, capturedAt: 10, scrollback: "closed"),
            ],
            removals: [],
            livePanelIds: [kept, cleared, closed]
        ))
        #expect(store.loadRecords(panelIds: [kept, cleared, closed]).count == 3)
        #expect(store.loadRecords(panelIds: [kept])[kept]?.scrollback.count
            == SessionPersistencePolicy.maxScrollbackCharactersPerTerminal)

        store.apply(.init(
            captures: [.init(panelId: cleared, capturedAt: 20, scrollback: "  \n")],
            removals: [],
            livePanelIds: [kept, cleared]
        ))
        let records = store.loadRecords(panelIds: [kept, cleared, closed])
        #expect(Set(records.keys) == [kept])
    }

    @Test func restoreFillsMissingScrollbackFromCheckpoint() throws {
        let store = makeStore()
        defer { cleanUp(store) }
        let panel = UUID()
        let dockPanel = UUID()
        store.apply(.init(
            captures: [
                .init(panelId: panel, capturedAt: 100, scrollback: "checkpointed\n"),
                .init(panelId: dockPanel, capturedAt: 100, scrollback: "dock\n"),
            ],
            removals: [],
            livePanelIds: [panel, dockPanel]
        ))

        let merged = store.merging(into: Self.snapshot(
            createdAt: 200,
            panels: [(panel, nil)],
            dockPanels: [(dockPanel, nil)]
        ))

        let workspace = try #require(merged.windows.first?.tabManager.workspaces.first)
        #expect(workspace.panels.first?.terminal?.scrollback == "checkpointed\n")
        #expect(merged.windows.first?.dock?.panels.first?.terminal?.scrollback == "dock\n")
    }

    @Test func restorePicksTheNewestScrollback() {
        let checkpoint = SessionScrollbackCheckpointRecord(
            version: SessionScrollbackCheckpointRecord.currentVersion,
            panelId: UUID(),
            capturedAt: 100,
            scrollback: "checkpoint"
        )
        #expect(SessionScrollbackCheckpointMerge.resolvedScrollback(
            snapshotScrollback: "quit", snapshotCreatedAt: 200, checkpoint: checkpoint
        ) == "quit")
        #expect(SessionScrollbackCheckpointMerge.resolvedScrollback(
            snapshotScrollback: "quit", snapshotCreatedAt: 50, checkpoint: checkpoint
        ) == "checkpoint")
        #expect(SessionScrollbackCheckpointMerge.resolvedScrollback(
            snapshotScrollback: nil, snapshotCreatedAt: 200, checkpoint: checkpoint
        ) == "checkpoint")
        #expect(SessionScrollbackCheckpointMerge.resolvedScrollback(
            snapshotScrollback: "quit", snapshotCreatedAt: 200, checkpoint: nil
        ) == "quit")
    }

    @Test func laterCheckpointReplacesEarlierOne() throws {
        let store = makeStore()
        defer { cleanUp(store) }
        let panel = UUID()
        store.apply(.init(
            captures: [.init(panelId: panel, capturedAt: 100, scrollback: "first\n")],
            removals: [],
            livePanelIds: [panel]
        ))
        store.apply(.init(
            captures: [.init(panelId: panel, capturedAt: 160, scrollback: "second\n")],
            removals: [],
            livePanelIds: [panel]
        ))

        let merged = store.merging(into: Self.snapshot(createdAt: 170, panels: [(panel, nil)]))
        #expect(merged.windows.first?.tabManager.workspaces.first?.panels.first?.terminal?.scrollback
            == "second\n")
    }

    @Test func ignoresRecordsFiledUnderAnotherPanel() throws {
        let store = makeStore()
        defer { cleanUp(store) }
        let panel = UUID()
        let other = UUID()
        let record = SessionScrollbackCheckpointRecord(
            version: SessionScrollbackCheckpointRecord.currentVersion,
            panelId: other,
            capturedAt: 1,
            scrollback: "wrong"
        )
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: store.fileURL(panelId: panel))

        #expect(store.loadRecords(panelIds: [panel]).isEmpty)
    }

    private static func snapshot(
        createdAt: TimeInterval,
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
            ]
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
