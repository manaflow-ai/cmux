import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct SessionPriorityManualSignalsTests {
    private func detect(
        flag: Bool = false,
        args: [String] = ["claude"],
        launchEnv: [String: String] = [:],
        env: [String: String] = [:],
        screen: String? = nil
    ) -> SessionPriorityManualSignal? {
        SessionPriorityManualSignals.detect(
            userFlag: flag,
            launchArguments: args,
            launchEnvironment: launchEnv,
            workspaceEnvironment: env,
            screenText: screen
        )
    }

    @Test
    func effortArgumentIsManual() {
        #expect(detect(args: ["claude", "--effort", "high"]) == .launchArgumentEffort)
        #expect(detect(args: ["claude", "--effort=high"]) == .launchArgumentEffort)
    }

    @Test
    func modelArgumentIsNotManual() {
        #expect(detect(args: ["claude", "--model", "opus"]) == nil)
    }

    /// `CLAUDE_CODE_EFFORT_LEVEL=max claude`, or the variable exported by an rc file, is the
    /// user's choice: cmux's own resume always marks the level it sets.
    @Test
    func launchEnvironmentEffortWithoutTheMarkerIsManual() {
        #expect(detect(launchEnv: ["CLAUDE_CODE_EFFORT_LEVEL": "max"]) == .launchEnvironmentEffort)
        #expect(detect(launchEnv: [
            "CLAUDE_CODE_EFFORT_LEVEL": "max",
            "CMUX_SESSION_PRIORITY_EFFORT": "high",
        ]) == .launchEnvironmentEffort)
    }

    @Test
    func markedLaunchEnvironmentEffortIsCmuxs() {
        #expect(detect(launchEnv: [
            "CLAUDE_CODE_EFFORT_LEVEL": "high",
            "CMUX_SESSION_PRIORITY_EFFORT": "high",
        ]) == nil)
        #expect(detect(launchEnv: ["CMUX_SESSION_PRIORITY_EFFORT": "high"]) == nil)
        #expect(detect(launchEnv: ["CLAUDE_CODE_EFFORT_LEVEL": "  "]) == nil)
    }

    @Test
    func workspaceEnvironmentEffortIsManual() {
        #expect(detect(env: ["CLAUDE_CODE_EFFORT_LEVEL": "high"]) == .workspaceEnvironmentEffort)
        #expect(detect(env: ["CLAUDE_CODE_EFFORT_LEVEL": "  "]) == nil)
    }

    @Test
    func screenMarkerIsManual() {
        #expect(detect(screen: "> /effort high\nEffort level set to high") == .userCommandOnScreen)
        #expect(detect(screen: "⎿  Set effort level to max (this session only)") == .userCommandOnScreen)
        #expect(detect(screen: "Model set to opus") == .userCommandOnScreen)
        #expect(detect(screen: "⎿  Set model to `Opus 5.5` and saved as your default") == .userCommandOnScreen)
        #expect(detect(screen: "nothing here") == nil)
    }

    @Test
    func signalsFollowTheDocumentedOrder() {
        let launchEnv = ["CLAUDE_CODE_EFFORT_LEVEL": "low"]
        let env = ["CLAUDE_CODE_EFFORT_LEVEL": "low"]
        let screen = "Model set to x"
        #expect(detect(flag: true, args: ["claude", "--effort", "low"], launchEnv: launchEnv, env: env, screen: screen) == .flag)
        #expect(detect(args: ["claude", "--effort", "low"], launchEnv: launchEnv, env: env, screen: screen) == .launchArgumentEffort)
        #expect(detect(launchEnv: launchEnv, env: env, screen: screen) == .launchEnvironmentEffort)
        #expect(detect(env: env, screen: screen) == .workspaceEnvironmentEffort)
        #expect(detect(screen: screen) == .userCommandOnScreen)
    }

    /// The socket's `manual_signal` and `cmux session-priority --json` carry these raw values.
    @Test
    func wireValuesAreStable() {
        let wire: [SessionPriorityManualSignal: String] = [
            .flag: "flag",
            .launchArgumentEffort: "launchArgumentEffort",
            .launchEnvironmentEffort: "launchEnvironmentEffort",
            .workspaceEnvironmentEffort: "workspaceEnvironmentEffort",
            .userCommandOnScreen: "userCommandOnScreen",
        ]
        for (signal, value) in wire {
            #expect(signal.rawValue == value)
        }
    }

    @Test
    func screenMarkersMatchTheTranscriptProbe() {
        #expect(SessionPriorityManualSignals.screenMarkers == ClaudeTranscriptLocalCommandProbe.changeMarkers)
        #expect(SessionPriorityManualSignals.screenMarkers.contains("Set model to"))
    }
}
