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
        env: [String: String] = [:],
        screen: String? = nil
    ) -> SessionPriorityManualSignal? {
        SessionPriorityManualSignals.detect(
            userFlag: flag, launchArguments: args, workspaceEnvironment: env, screenText: screen
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

    @Test
    func workspaceEnvironmentEffortIsManual() {
        #expect(detect(env: ["CLAUDE_CODE_EFFORT_LEVEL": "high"]) == .workspaceEnvironmentEffort)
        #expect(detect(env: ["CLAUDE_CODE_EFFORT_LEVEL": "  "]) == nil)
    }

    @Test
    func screenMarkerIsManual() {
        #expect(detect(screen: "> /effort high\nEffort level set to high") == .userCommandOnScreen)
        #expect(detect(screen: "Model set to opus") == .userCommandOnScreen)
        #expect(detect(screen: "nothing here") == nil)
    }

    @Test
    func flagWinsFirst() {
        #expect(detect(
            flag: true,
            args: ["claude", "--effort", "low"],
            env: ["CLAUDE_CODE_EFFORT_LEVEL": "low"],
            screen: "Model set to x"
        ) == .flag)
    }
}
