import CMUXAgentLaunch
import Foundation
import Testing

// ClaudeDifficultyAssessmentStore is compiled directly into this test target,
// like DifficultyAssessmentEngine, so the store runs in-process against a
// temporary directory.

/// The per-session throttle and verdict history of the automatic difficulty
/// pass, kept where `SessionEnd` cannot remove it.
@Suite struct CLIDifficultyAssessmentStoreTests {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func makeStore() throws -> (ClaudeDifficultyAssessmentStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-difficulty-store-\(UUID().uuidString)", isDirectory: true)
        let store = ClaudeDifficultyAssessmentStore(processEnv: [
            "CMUX_CLAUDE_HOOK_STATE_PATH": root.appendingPathComponent("claude-hook-sessions.json").path,
        ])
        return (store, root)
    }

    @Test func livesNextToTheHookSessionStore() {
        let hookPath = ClaudeDifficultyAssessmentStore(processEnv: [
            "CMUX_CLAUDE_HOOK_STATE_PATH": "/tmp/a/hooks.json",
            "CMUX_AGENT_HOOK_STATE_DIR": "/tmp/b",
        ])
        let stateDir = ClaudeDifficultyAssessmentStore(processEnv: ["CMUX_AGENT_HOOK_STATE_DIR": "/tmp/b"])
        let defaultPath = ClaudeDifficultyAssessmentStore(processEnv: [:])
        #expect(hookPath.path == "/tmp/a/claude-difficulty-assessments.json")
        #expect(stateDir.path == "/tmp/b/claude-difficulty-assessments.json")
        #expect(defaultPath.path.hasSuffix("/.cmuxterm/claude-difficulty-assessments.json"))
    }

    @Test func beginMarksInFlightAndFinishStartsTheWindow() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let min = DifficultyAssessmentConfig.minInterval

        #expect(try store.begin(sessionId: "s1", now: t0).decision == .proceed)
        #expect(try store.begin(sessionId: "s1", now: t0.addingTimeInterval(1)).decision == .skipInFlight)
        try store.finish(sessionId: "s1", verdict: .hard, now: t0.addingTimeInterval(5))
        let entry = try #require(try store.entry(sessionId: "s1"))
        #expect(entry.inFlightAt == nil)
        #expect(entry.lastAssessedAt == t0.addingTimeInterval(5).timeIntervalSince1970)
        #expect(entry.lastVerdict == "hard")

        #expect(try store.begin(sessionId: "s1", now: t0.addingTimeInterval(5 + min - 1)).decision == .skipTooSoon)
        #expect(try store.begin(sessionId: "s1", now: t0.addingTimeInterval(5 + min)).decision == .proceed)
        #expect(try store.begin(sessionId: "s2", now: t0.addingTimeInterval(6)).decision == .proceed, "sessions are independent")
    }

    /// A Claude restart removes the session's hook record; the difficulty store is a
    /// different file, and the next store (a new hook process) still sees the window.
    @Test func windowSurvivesTheHookRecordAndANewProcess() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.begin(sessionId: "s1", now: t0)
        try store.finish(sessionId: "s1", verdict: .easy, now: t0)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("claude-hook-sessions.json"))

        let next = ClaudeDifficultyAssessmentStore(processEnv: [
            "CMUX_CLAUDE_HOOK_STATE_PATH": root.appendingPathComponent("claude-hook-sessions.json").path,
        ])
        let start = try next.begin(sessionId: "s1", now: t0.addingTimeInterval(99))
        #expect(start.decision == .skipTooSoon)
        #expect(start.previousVerdict == .easy)
    }

    @Test func aRunWithoutAVerdictKeepsThePreviousOne() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.begin(sessionId: "s1", now: t0)
        try store.finish(sessionId: "s1", verdict: .easy, now: t0)
        let later = t0.addingTimeInterval(DifficultyAssessmentConfig.minInterval)
        #expect(try store.begin(sessionId: "s1", now: later).previousVerdict == .easy)
        try store.finish(sessionId: "s1", verdict: nil, now: later)
        let entry = try #require(try store.entry(sessionId: "s1"))
        #expect(entry.lastVerdict == "easy")
        #expect(entry.lastAssessedAt == later.timeIntervalSince1970, "a failed call still starts the window")
    }

    @Test func entriesUntouchedForADayArePrunedOnTheNextWrite() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.begin(sessionId: "old", now: t0)
        try store.finish(sessionId: "old", verdict: .hard, now: t0)
        let retention = DifficultyAssessmentConfig.storeRetention

        _ = try store.begin(sessionId: "new", now: t0.addingTimeInterval(retention - 1))
        #expect(try store.entry(sessionId: "old") != nil)
        _ = try store.begin(sessionId: "new", now: t0.addingTimeInterval(retention + 1))
        #expect(try store.entry(sessionId: "old") == nil)
    }

    @Test func unreadableFileStartsEmpty() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: URL(fileURLWithPath: store.path))
        #expect(try store.begin(sessionId: "s1", now: t0).decision == .proceed)
    }

    @Test func blankSessionIdIsNeverAssessed() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try store.begin(sessionId: "  ", now: t0).decision != .proceed)
        #expect(try store.entry(sessionId: "  ") == nil)
    }
}
