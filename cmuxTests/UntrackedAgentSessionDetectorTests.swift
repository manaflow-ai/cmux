import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the untracked-session detector: the full warn/skip matrix,
/// the grace window that suppresses SessionStart-latency false positives, the
/// once-per-pane dedupe, the opt-out, and ordered precedence of the guards.
@Suite struct UntrackedAgentSessionDetectorTests {

    private func facts(
        kind: RestorableAgentKind? = .claude,
        hasProcess: Bool = true,
        hasHook: Bool = false,
        secondsWithoutHook: TimeInterval = 30,
        alreadyWarned: Bool = false,
        enabled: Bool = true
    ) -> PaneTrackingFacts {
        PaneTrackingFacts(
            agentKind: kind,
            hasProcessDetectedAgent: hasProcess,
            hasHookProvenSession: hasHook,
            secondsDetectedWithoutHook: secondsWithoutHook,
            alreadyWarned: alreadyWarned,
            warningEnabled: enabled
        )
    }

    private let detector = UntrackedAgentSessionDetector(graceInterval: 10)

    @Test func liveAgentWithNoHookPastGraceWarns() {
        // Covers R1: a detected agent with no hook session, past grace, warns.
        #expect(detector.decide(facts()) == .warn)
        #expect(detector.shouldWarn(facts()) == true)
    }

    @Test func codexAlsoWarns() {
        #expect(detector.decide(facts(kind: .codex)) == .warn)
    }

    @Test func hookProvenSessionIsTracked() {
        // A recorded hook session means the pane IS tracked — never warn.
        #expect(detector.decide(facts(hasHook: true)) == .skip(.tracked))
    }

    @Test func withinGraceIsNotWarned() {
        // Covers R2: SessionStart latency must not be flagged as a bypass.
        #expect(detector.decide(facts(secondsWithoutHook: 5)) == .skip(.withinGrace))
        // Boundary: exactly at grace warns.
        #expect(detector.decide(facts(secondsWithoutHook: 10)) == .warn)
        #expect(detector.decide(facts(secondsWithoutHook: 9.99)) == .skip(.withinGrace))
    }

    @Test func alreadyWarnedSkips() {
        // Covers R4: warn at most once per pane/session.
        #expect(detector.decide(facts(alreadyWarned: true)) == .skip(.alreadyWarned))
    }

    @Test func disabledSettingSkips() {
        // Covers R5.
        #expect(detector.decide(facts(enabled: false)) == .skip(.disabled))
    }

    @Test func noAgentProcessSkips() {
        #expect(detector.decide(facts(hasProcess: false)) == .skip(.noAgent))
        #expect(detector.decide(facts(kind: nil)) == .skip(.noAgent))
    }

    @Test func unsupportedAgentSkips() {
        #expect(detector.decide(facts(kind: .gemini)) == .skip(.unsupported(.gemini)))
        #expect(detector.decide(facts(kind: .custom("acme"))) == .skip(.unsupported(.custom("acme"))))
    }

    // MARK: - Ordered precedence

    @Test func disabledBeatsEveryOtherReason() {
        // Even a clear bypass is silent when the setting is off.
        let f = facts(kind: .gemini, hasProcess: true, hasHook: false, secondsWithoutHook: 999, enabled: false)
        #expect(detector.decide(f) == .skip(.disabled))
    }

    @Test func noAgentBeatsTracked() {
        // No process at all reports noAgent, not tracked.
        #expect(detector.decide(facts(hasProcess: false, hasHook: true)) == .skip(.noAgent))
    }

    @Test func trackedBeatsGraceAndUnsupported() {
        // A tracked pane is the happy path regardless of grace/kind.
        #expect(detector.decide(facts(hasHook: true, secondsWithoutHook: 0)) == .skip(.tracked))
        #expect(detector.decide(facts(kind: .gemini, hasHook: true)) == .skip(.tracked))
    }

    @Test func unsupportedBeatsGrace() {
        #expect(detector.decide(facts(kind: .gemini, secondsWithoutHook: 1)) == .skip(.unsupported(.gemini)))
    }

    @Test func graceBeatsAlreadyWarned() {
        // Within grace we never reach the dedupe check.
        #expect(detector.decide(facts(secondsWithoutHook: 1, alreadyWarned: true)) == .skip(.withinGrace))
    }

    @Test func customGraceIntervalRespected() {
        let strict = UntrackedAgentSessionDetector(graceInterval: 30)
        #expect(strict.decide(facts(secondsWithoutHook: 20)) == .skip(.withinGrace))
        #expect(strict.decide(facts(secondsWithoutHook: 30)) == .warn)
    }
}
