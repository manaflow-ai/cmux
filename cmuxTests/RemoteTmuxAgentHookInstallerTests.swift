import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests the pure builders for the remote agent-status hook install (Option C).
/// The end-to-end channel was verified live (tmux 3.6a delivers
/// `%subscription-changed cmux_agent_<pane>` when a hook sets `@cmux_agent`); these
/// lock the hook script shape, the per-agent event map, and the JSON contract the
/// `RemoteTmuxAgentStatus` parser consumes.
@Suite struct RemoteTmuxAgentHookInstallerTests {
    typealias Installer = RemoteTmuxAgentHookInstaller

    @Test func hookScriptScopesToTmuxPaneAndSelfDisablesOutsideTmux() {
        let script = Installer.hookScript(agent: "claude", state: "working")
        // Self-disables when not inside tmux.
        #expect(script.contains("TMUX_PANE"))
        // Scopes the option to the agent's own pane (not the client's active pane).
        #expect(script.contains(#"tmux set -t "$TMUX_PANE" @cmux_agent"#))
        // Carries the agent label + state into the JSON.
        #expect(script.contains(#"\"agent\":\"claude\""#))
        #expect(script.contains(#"\"state\":\"working\""#))
        // Always prints a JSON object so a blocking hook gets valid stdout.
        #expect(script.contains("printf '{}'"))
        // Best-effort model extraction from the event JSON on stdin.
        #expect(script.contains(#"\"model\":"#))
    }

    @Test func claudeHooksCoverLifecycleWithExpectedStates() {
        let obj = Installer.claudeHooksObject()
        #expect(Set(obj.keys) == ["SessionStart", "UserPromptSubmit", "Stop"])
        // Each event maps to the right reported state.
        #expect(commandForEvent(obj, "SessionStart").contains(#"\"state\":\"running\""#))
        #expect(commandForEvent(obj, "UserPromptSubmit").contains(#"\"state\":\"working\""#))
        #expect(commandForEvent(obj, "Stop").contains(#"\"state\":\"idle\""#))
        // Every entry is cmux-marked so install can replace only its own.
        #expect(markerPresent(obj, "Stop"))
    }

    @Test func codexHooksUseNestedShapeAndCodexAgentLabel() {
        let obj = Installer.codexHooksObject()
        #expect(Set(obj.keys) == ["SessionStart", "UserPromptSubmit", "Stop"])
        let cmd = commandForEvent(obj, "UserPromptSubmit")
        #expect(cmd.contains(#"\"agent\":\"codex\""#))
        #expect(cmd.contains(#"\"state\":\"working\""#))
    }

    @Test func installCommandsRunPythonMergerWithHooksInEnv() {
        let claude = Installer.claudeInstallCommand()
        #expect(claude.first == "sh")
        #expect(claude.last?.contains("python3 -c") == true)
        #expect(claude.last?.contains("CMUX_HOOKS=") == true)
        #expect(claude.last?.contains(".claude/settings.json") == true)
        let codex = Installer.codexInstallCommand()
        #expect(codex.last?.contains("hooks.json") == true)
        #expect(codex.last?.contains("CODEX_HOME") == true)
    }

    @Test func generatedJSONParsesBackToTheStatusContract() {
        // The hook writes the same JSON shape RemoteTmuxAgentStatus.parse consumes.
        // Reconstruct what the hook emits for Stop (no model) and confirm it parses.
        let noModel = #"{"agent":"claude","state":"idle"}"#
        let withModel = #"{"agent":"codex","state":"working","model":"gpt-x"}"#
        #expect(RemoteTmuxAgentStatus.parse(noModel)?.state == .idle)
        #expect(RemoteTmuxAgentStatus.parse(withModel)?.model == "gpt-x")
    }

    // Helpers: dig the command string / marker out of the nested hook object.
    private func commandForEvent(_ obj: [String: Any], _ event: String) -> String {
        guard let arr = obj[event] as? [[String: Any]],
              let first = arr.first,
              let hooks = first["hooks"] as? [[String: Any]],
              let cmd = hooks.first?["command"] as? String else { return "" }
        return cmd
    }

    private func markerPresent(_ obj: [String: Any], _ event: String) -> Bool {
        guard let arr = obj[event] as? [[String: Any]],
              let first = arr.first,
              let hooks = first["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["_cmux"] as? String) == Installer.marker }
    }
}
