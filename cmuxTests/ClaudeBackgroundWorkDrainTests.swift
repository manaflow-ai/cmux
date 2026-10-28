import CmuxAgentJournal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A Claude pane whose background work ended while the agent sat idle must
/// settle to idle instead of staying `backgroundWorkPending` forever.
/// https://github.com/manaflow-ai/cmux/issues/26358
@Suite
struct ClaudeBackgroundWorkDrainTests {
    private typealias Fixture = AgentHibernationBackgroundWorkTests.TranscriptFixture
    private static let workspaceId = UUID()
    private static let panelId = UUID()
    private static let sessionId = "drain-session"

    // MARK: Transcript and process evidence

    @Test
    func completedBackgroundBashCountsAsDrained() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([
            AgentHibernationBackgroundWorkTests.userTurn,
            AgentHibernationBackgroundWorkTests.backgroundBashLaunch(toolUseID: "toolu_bash", taskID: "bshell1"),
            AgentHibernationBackgroundWorkTests.queuedNotification(toolUseID: "toolu_bash", taskID: "bshell1", status: "completed"),
        ])

        #expect(drained(fixture, processScopeShowsNoBackgroundShell: false))
    }

    @Test
    func unreportedBashCountsAsDrainedOnlyWithoutALiveShell() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([
            AgentHibernationBackgroundWorkTests.userTurn,
            AgentHibernationBackgroundWorkTests.backgroundBashLaunch(toolUseID: "toolu_bash", taskID: "bshell1"),
        ])

        #expect(drained(fixture, processScopeShowsNoBackgroundShell: true))
        #expect(!drained(fixture, processScopeShowsNoBackgroundShell: false))
    }

    @Test
    func unreportedAsyncSubagentNeverCountsAsDrained() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([
            AgentHibernationBackgroundWorkTests.userTurn,
            AgentHibernationBackgroundWorkTests.asyncAgentLaunch(toolUseID: "toolu_agent", agentID: "a1234567890abcdef"),
        ])

        // A subagent runs inside the agent process; an empty process scope
        // says nothing about it.
        #expect(!drained(fixture, processScopeShowsNoBackgroundShell: true))
    }

    @Test
    func aSessionWithPendingCronsNeverCountsAsDrained() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([
            AgentHibernationBackgroundWorkTests.userTurn,
            AgentHibernationBackgroundWorkTests.backgroundBashLaunch(toolUseID: "toolu_bash", taskID: "bshell1"),
            AgentHibernationBackgroundWorkTests.queuedNotification(toolUseID: "toolu_bash", taskID: "bshell1", status: "completed"),
        ])

        // The transcript shows every task finished, but a scheduled wakeup
        // leaves no trace there.
        #expect(!drained(fixture, processScopeShowsNoBackgroundShell: true, sessionCrons: true))
        // A record from before the flag existed proves nothing either.
        #expect(!drained(fixture, processScopeShowsNoBackgroundShell: true, sessionCrons: nil))
    }

    @Test
    func aRecentlyWrittenTranscriptIsLeftForALaterCheck() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([
            AgentHibernationBackgroundWorkTests.userTurn,
            AgentHibernationBackgroundWorkTests.backgroundBashLaunch(toolUseID: "toolu_bash", taskID: "bshell1"),
            AgentHibernationBackgroundWorkTests.queuedNotification(toolUseID: "toolu_bash", taskID: "bshell1", status: "completed"),
        ])

        // The finished task may have woken Claude for a turn whose hook has
        // not landed; a fresh transcript write is the sign of that.
        #expect(!drained(fixture, processScopeShowsNoBackgroundShell: true, now: Date()))
    }

    @Test
    func aTranscriptWithNoLaunchNeverCountsAsDrained() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // The launch predates the scanned tail, or is a kind the parser does
        // not know: nothing proves the work Stop reported has ended.
        try fixture.write([AgentHibernationBackgroundWorkTests.userTurn])

        #expect(!drained(fixture, processScopeShowsNoBackgroundShell: true))
    }

    @Test
    func unchangedEvidenceIsNotReadAgainButChangedEvidenceIs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // A whole-second mtime survives the round trip through the file system.
        let modifiedAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3_600).rounded(.down))
        func write(_ lines: [String]) throws {
            try fixture.write(lines)
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: fixture.transcriptURL.path)
        }
        try write([
            AgentHibernationBackgroundWorkTests.userTurn,
            AgentHibernationBackgroundWorkTests.backgroundBashLaunch(toolUseID: "toolu_bash", taskID: "bshell1"),
        ])

        // A live shell keeps the unreported command pending.
        guard case .pending(let evidence) = verdict(fixture, processScopeShowsNoBackgroundShell: false) else {
            Issue.record("expected a pending verdict")
            return
        }
        // The shell exited: the process scope changed, so the check reads again.
        #expect(verdict(fixture, processScopeShowsNoBackgroundShell: true, unchangedSince: evidence) == .drained)

        // The transcript now says drained, but its mtime and the process scope
        // match the rejected evidence, so it is not read.
        try write([
            AgentHibernationBackgroundWorkTests.userTurn,
            AgentHibernationBackgroundWorkTests.backgroundBashLaunch(toolUseID: "toolu_bash", taskID: "bshell1"),
            AgentHibernationBackgroundWorkTests.queuedNotification(toolUseID: "toolu_bash", taskID: "bshell1", status: "completed"),
        ])
        #expect(verdict(fixture, processScopeShowsNoBackgroundShell: false, unchangedSince: evidence) == .pending(evidence))
        #expect(verdict(fixture, processScopeShowsNoBackgroundShell: false) == .drained)
    }

    @Test
    func missingTranscriptNeverCountsAsDrained() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(!drained(fixture, processScopeShowsNoBackgroundShell: true))
    }

    @Test
    func onlyQuietPendingClaudePanesAreChecked() {
        let now: TimeInterval = 10_000
        func check(
            kind: RestorableAgentKind = .claude,
            lifecycle: AgentHibernationLifecycleState? = .backgroundWorkPending,
            hibernated: Bool = false,
            changedAt: TimeInterval? = now - 120
        ) -> Bool {
            ClaudeBackgroundWorkDrain.shouldCheck(
                agentKind: kind,
                claudeLifecycle: lifecycle,
                isHibernated: hibernated,
                lifecycleChangedAt: changedAt,
                now: now
            )
        }

        #expect(check())
        #expect(check(changedAt: nil))
        #expect(!check(changedAt: now - 5))
        #expect(!check(lifecycle: .idle))
        #expect(!check(lifecycle: .running))
        #expect(!check(kind: .codex))
        #expect(!check(hibernated: true))
    }

    // MARK: Journal projection

    @Test
    func drainEventSettlesAPendingPaneToIdleAndReplacesItsPill() {
        var pipeline = Pipeline()
        pipeline.apply(Self.draft(.sessionStarted, atMs: 1_000))
        pipeline.apply(Self.draft(.turnStarted, atMs: 2_000))
        let stop = pipeline.apply(Self.draft(.turnCompleted, atMs: 3_000, pendingWork: true))
        #expect(stop?.assignment.phase == .backgroundWorkPending)

        let drain = pipeline.apply(ClaudeBackgroundWorkDrain.drainedDraft(
            sessionId: Self.sessionId,
            workspaceId: Self.workspaceId,
            panelId: Self.panelId,
            observedAt: Date(timeIntervalSince1970: 60)
        ))

        #expect(drain?.assignment.phase == .idle)
        #expect(drain?.settledDrainedBackgroundWork == true)
    }

    @Test
    func drainEventLosesToATurnThatStartedAfterTheCheck() {
        var pipeline = Pipeline()
        pipeline.apply(Self.draft(.sessionStarted, atMs: 1_000))
        pipeline.apply(Self.draft(.turnStarted, atMs: 2_000))
        pipeline.apply(Self.draft(.turnCompleted, atMs: 3_000, pendingWork: true))
        // The finished task woke Claude after the check read the transcript,
        // but its hook committed first.
        let wake = pipeline.apply(Self.draft(.turnStarted, atMs: 61_000))
        #expect(wake?.assignment.phase == .running)

        let drain = pipeline.apply(ClaudeBackgroundWorkDrain.drainedDraft(
            sessionId: Self.sessionId,
            workspaceId: Self.workspaceId,
            panelId: Self.panelId,
            observedAt: Date(timeIntervalSince1970: 60)
        ))

        #expect(drain == nil || drain?.assignment.phase == .running)
        #expect(drain?.settledDrainedBackgroundWork != true)
        #expect(pipeline.phase == .running)
    }

    @Test
    func drainEventLosesToATurnStampedBeforeTheCheckButCommittedFirst() {
        var pipeline = Pipeline()
        pipeline.apply(Self.draft(.sessionStarted, atMs: 1_000))
        pipeline.apply(Self.draft(.turnStarted, atMs: 2_000))
        pipeline.apply(Self.draft(.turnCompleted, atMs: 3_000, pendingWork: true))
        // The prompt hook fired just before the check read the clock, and its
        // journal append landed before the drain event.
        pipeline.apply(Self.draft(.turnStarted, atMs: 59_000))

        let drain = pipeline.apply(ClaudeBackgroundWorkDrain.drainedDraft(
            sessionId: Self.sessionId,
            workspaceId: Self.workspaceId,
            panelId: Self.panelId,
            observedAt: Date(timeIntervalSince1970: 60)
        ))

        #expect(drain == nil)
        #expect(pipeline.phase == .running)
    }

    @Test
    func aTurnStampedBeforeTheCheckButCommittedAfterTheDrainStillRuns() {
        var pipeline = Pipeline()
        pipeline.apply(Self.draft(.sessionStarted, atMs: 1_000))
        pipeline.apply(Self.draft(.turnStarted, atMs: 2_000))
        pipeline.apply(Self.draft(.turnCompleted, atMs: 3_000, pendingWork: true))
        let drain = pipeline.apply(ClaudeBackgroundWorkDrain.drainedDraft(
            sessionId: Self.sessionId,
            workspaceId: Self.workspaceId,
            panelId: Self.panelId,
            observedAt: Date(timeIntervalSince1970: 60)
        ))
        #expect(drain?.assignment.phase == .idle)

        // The prompt hook fired just before the check read the clock, but its
        // journal append landed after the drain event.
        let wake = pipeline.apply(Self.draft(.turnStarted, atMs: 59_000))

        #expect(wake?.assignment.phase == .running)
        #expect(pipeline.phase == .running)
    }

    @Test
    func aHookCompletionDoesNotRewriteThePill() {
        var pipeline = Pipeline()
        pipeline.apply(Self.draft(.sessionStarted, atMs: 1_000))
        pipeline.apply(Self.draft(.turnStarted, atMs: 2_000))
        pipeline.apply(Self.draft(.turnCompleted, atMs: 3_000, pendingWork: true))
        pipeline.apply(Self.draft(.turnStarted, atMs: 4_000))
        let stop = pipeline.apply(Self.draft(.turnCompleted, atMs: 5_000))

        #expect(stop?.assignment.phase == .idle)
        #expect(stop?.settledDrainedBackgroundWork == false)
    }

    // MARK: Helpers

    private func drained(
        _ fixture: Fixture,
        processScopeShowsNoBackgroundShell: Bool,
        sessionCrons: Bool? = false,
        now: Date = Date().addingTimeInterval(ClaudeBackgroundWorkDrain.quietSeconds + 60)
    ) -> Bool {
        verdict(
            fixture,
            processScopeShowsNoBackgroundShell: processScopeShowsNoBackgroundShell,
            sessionCrons: sessionCrons,
            now: now
        ) == .drained
    }

    private func verdict(
        _ fixture: Fixture,
        processScopeShowsNoBackgroundShell: Bool,
        sessionCrons: Bool? = false,
        unchangedSince: ClaudeBackgroundWorkDrain.Evidence? = nil,
        now: Date = Date().addingTimeInterval(ClaudeBackgroundWorkDrain.quietSeconds + 60)
    ) -> ClaudeBackgroundWorkDrain.Verdict {
        let storeURL = fixture.home.appendingPathComponent("claude-hook-sessions.json", isDirectory: false)
        var record: [String: Any] = [
            "sessionId": fixture.sessionId,
            "workspaceId": Self.workspaceId.uuidString,
            "surfaceId": Self.panelId.uuidString,
            "agentLifecycle": "backgroundWorkPending",
            "updatedAt": 1,
        ]
        if let sessionCrons { record["hadSessionCronsAtStop"] = sessionCrons }
        let store: [String: Any] = ["version": 1, "sessions": [fixture.sessionId: record]]
        try? JSONSerialization.data(withJSONObject: store).write(to: storeURL)
        return ClaudeBackgroundWorkDrain.verdict(
            agent: SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: fixture.sessionId,
                workingDirectory: fixture.cwd,
                launchCommand: nil
            ),
            panelKey: nil,
            notBefore: nil,
            processScopeShowsNoBackgroundShell: processScopeShowsNoBackgroundShell,
            unchangedSince: unchangedSince,
            now: now,
            homeDirectory: fixture.home.path,
            hookStoreURL: storeURL
        )
    }

    private static func draft(
        _ kind: AgentJournalEventKind,
        atMs occurredAtMs: Int64,
        pendingWork: Bool = false
    ) -> AgentJournalEventDraft {
        AgentJournalEventDraft(
            kind: kind,
            occurredAtMs: occurredAtMs,
            source: "claude",
            agentKey: ClaudeBackgroundWorkDrain.statusKey,
            sessionId: sessionId,
            workspaceId: workspaceId.uuidString,
            surfaceId: panelId.uuidString,
            pendingWork: pendingWork,
            nativeEvent: kind.rawValue
        )
    }

    /// The live journal consumer's order: admit (or drop) a drain event,
    /// reconcile, then reduce the reconciled lifecycle event.
    private struct Pipeline {
        private var notifications = AgentNotificationReconciler()
        private var state = AgentLifecycleReducerState()
        private let reducer = AgentLifecycleReducer()
        private var sequence: Int64 = 0

        var phase: AgentLifecyclePhase? {
            state.combinedPhase(surfaceId: ClaudeBackgroundWorkDrainTests.panelId.uuidString, agentKey: ClaudeBackgroundWorkDrain.statusKey)
        }

        @discardableResult
        mutating func apply(_ draft: AgentJournalEventDraft) -> AgentJournalLifecycleCenter.LifecycleApplication? {
            sequence += 1
            guard let event = AgentJournalLifecycleCenter.admittingBackgroundWorkDrain(
                AgentJournalEvent(sequence: sequence, committedAtMs: sequence, draft: draft),
                state: state
            ) else { return nil }
            let decision = notifications.apply(event)
            guard decision.disposition != .stale, decision.projectsLifecycle else { return nil }
            return AgentJournalLifecycleCenter.reduceIngest(
                notifications.lifecycleEvent(event),
                sourceKind: event.kind,
                aliases: AgentJournalAliasResolver(),
                reducer: reducer,
                state: &state
            )
        }
    }
}
