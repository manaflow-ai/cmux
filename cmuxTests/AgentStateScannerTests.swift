import CmuxAgentJournal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent state scanner")
struct AgentStateScannerTests {
    private func observe(
        _ screen: String,
        _ previous: AgentStateScanner.Sample?,
        at now: TimeInterval,
        stillness: TimeInterval = 12
    ) -> (sample: AgentStateScanner.Sample, verdict: AgentStateScanner.Verdict) {
        AgentStateScanner.observe(
            screen: screen,
            previous: previous,
            now: now,
            stillnessSeconds: stillness
        )
    }

    /// A working agent redraws its elapsed-time counter, so a screen that keeps
    /// changing is never retired no matter how long the turn runs. This is the
    /// dangerous direction: retiring a live turn would paint a working pane as
    /// finished.
    @Test func aChangingScreenIsNeverStale() {
        var sample = observe("Cooked for 1s", nil, at: 0).sample
        for second in 1...60 {
            let result = observe(
                "Cooked for \(second)s",
                sample,
                at: TimeInterval(second)
            )
            #expect(result.verdict == .working, "a redrawing screen must stay working at t=\(second)")
            sample = result.sample
        }
    }

    /// The case that motivated the scanner: a prompt was submitted, the pane
    /// went running, and the turn was interrupted so no Stop hook ever fired.
    /// Nothing in the event stream can retire that - only the screen can.
    @Test func aStillScreenGoesStaleOnceTheWindowElapses() {
        let idle = "\n❯ \nsession:7m | ctx:[----------]0%"
        var sample = observe(idle, nil, at: 0).sample

        let earlier = observe(idle, sample, at: 5)
        #expect(earlier.verdict == .working, "stillness must be measured, not assumed")
        sample = earlier.sample

        #expect(observe(idle, sample, at: 12).verdict == .stale)
        #expect(observe(idle, sample, at: 40).verdict == .stale)
    }

    /// A first sighting is never stale, so a pane that starts working between
    /// two ticks cannot be retired on the strength of a single sample.
    @Test func aFirstSightingIsNeverStale() {
        #expect(observe("anything", nil, at: 10_000).verdict == .working)
    }

    /// A screen that moves resets the clock: an agent that pauses, prints, and
    /// pauses again must not accumulate stillness across the change.
    @Test func aChangeResetsTheStillnessClock() {
        var sample = observe("first", nil, at: 0).sample
        #expect(observe("first", sample, at: 11).verdict == .working)

        let changed = observe("second", sample, at: 11)
        #expect(changed.verdict == .working)
        sample = changed.sample

        // 11s of prior stillness must not count toward the new window.
        #expect(observe("second", sample, at: 20).verdict == .working)
        #expect(observe("second", sample, at: 23).verdict == .stale)
    }

    /// The retirement is journaled as an explicit idle assertion, which is the
    /// only kind the reducer honours a declared phase for. A different kind
    /// would be recorded and then silently ignored.
    @Test func theStaleEventAssertsIdleAsAStateChange() {
        let draft = AgentStateScanner.staleRunningEvent(
            agentKey: "claude_code",
            sessionId: nil,
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString,
            occurredAtMs: 1,
            eventId: "event-1"
        )
        #expect(draft.kind == .stateChanged)
        #expect(draft.declaredPhase == .idle)
        #expect(draft.source == "cmux.scanner")

        // And the reducer actually moves on it.
        let reducer = AgentLifecycleReducer()
        var state = AgentLifecycleReducerState()
        reducer.apply(
            AgentJournalEvent(sequence: 1, committedAtMs: 1, draft: draft),
            to: &state
        )
        #expect(
            state.combinedPhase(
                surfaceId: draft.surfaceId ?? "",
                agentKey: "claude_code"
            ) == .idle
        )
    }

    @Test func scanSettingsDefaultOnAndClamp() throws {
        let suiteName = "AgentStateScan.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(AgentStateScanSettings.intervalSeconds(defaults: defaults) == 5)
        #expect(AgentStateScanSettings.stillnessSeconds(defaults: defaults) == 12)

        // Zero disables; a mistyped tiny value cannot spin the runloop reading
        // every running pane's terminal.
        defaults.set(0.0, forKey: AgentStateScanSettings.intervalKey)
        #expect(AgentStateScanSettings.intervalSeconds(defaults: defaults) == 0)
        defaults.set(0.01, forKey: AgentStateScanSettings.intervalKey)
        #expect(AgentStateScanSettings.intervalSeconds(defaults: defaults) == 1)
        defaults.set(99_999.0, forKey: AgentStateScanSettings.intervalKey)
        #expect(AgentStateScanSettings.intervalSeconds(defaults: defaults) == 600)
    }
}
