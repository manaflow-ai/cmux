import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class RestorableAgentNonInteractiveTests: XCTestCase {
    func testHookStoreDirectoryCanBeOverriddenForTests() {
        let url = RestorableAgentKind.codex.hookStoreFileURL(
            homeDirectory: "/Users/example",
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": "/tmp/cmux hook state"]
        )

        XCTAssertEqual(url.path, "/tmp/cmux hook state/codex-hook-sessions.json")
    }

    func testNonInteractiveAgentLaunchesAreNotAutoRestored() {
        let claudePrint = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "claude",
                arguments: ["claude", "--print", "summarize this"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let claudePrintEquals = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-session-456",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "claude",
                arguments: ["claude", "--print=summarize this"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let codexExec = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "codex",
                arguments: ["codex", "exec", "fix this"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let opencodeRun = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "opencode",
                arguments: ["opencode", "run", "fix this"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let opencodePR = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-pr-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "opencode",
                arguments: ["opencode", "pr", "123"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let geminiPrompt = SessionRestorableAgentSnapshot(
            kind: .gemini,
            sessionId: "gemini-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "gemini",
                executablePath: "gemini",
                arguments: ["gemini", "--prompt", "fix this"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let rovoDevAuth = SessionRestorableAgentSnapshot(
            kind: .rovodev,
            sessionId: "rovo-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "rovodev",
                executablePath: "acli",
                arguments: ["acli", "rovodev", "auth", "login"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let cursorPrint = SessionRestorableAgentSnapshot(
            kind: .cursor,
            sessionId: "cursor-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "cursor",
                executablePath: "cursor-agent",
                arguments: ["cursor-agent", "--print", "fix this"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let copilotPrompt = SessionRestorableAgentSnapshot(
            kind: .copilot,
            sessionId: "copilot-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "copilot",
                executablePath: "copilot",
                arguments: ["copilot", "--prompt", "fix this"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let codeBuddyPrint = SessionRestorableAgentSnapshot(
            kind: .codebuddy,
            sessionId: "codebuddy-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codebuddy",
                executablePath: "codebuddy",
                arguments: ["codebuddy", "--print", "fix this"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let factoryExec = SessionRestorableAgentSnapshot(
            kind: .factory,
            sessionId: "factory-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "factory",
                executablePath: "droid",
                arguments: ["droid", "exec", "fix this"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let qoderPrint = SessionRestorableAgentSnapshot(
            kind: .qoder,
            sessionId: "qoder-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "qoder",
                executablePath: "qodercli",
                arguments: ["qodercli", "--print", "fix this"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        // NOTE: `pi --print "<prompt>"` is intentionally NOT in this set.
        // Unlike claude-code's --print mode, pi's -p / --print still writes
        // a session JSONL that Vault picks up. Commit e896b59 moved -p /
        // --print from rejectOptions to droppedOptions on purpose so the
        // recorded launch can be resumed as an interactive
        // `pi --session <id>` session. See piRestoresPrintLaunchAsInteractive
        // below for the positive case.
        let piExport = SessionRestorableAgentSnapshot(
            kind: .pi,
            sessionId: "pi-export-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "pi",
                executablePath: "pi",
                arguments: ["pi", "--export", "/tmp/foo.html"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let piInstall = SessionRestorableAgentSnapshot(
            kind: .pi,
            sessionId: "pi-install-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "pi",
                executablePath: "pi",
                // pi subcommands like `install`, `update`, `list` start no session.
                arguments: ["pi", "install", "./my-extension"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )

        XCTAssertNil(claudePrint.resumeCommand)
        XCTAssertNil(claudePrintEquals.resumeCommand)
        XCTAssertNil(codexExec.resumeCommand)
        XCTAssertNil(opencodeRun.resumeCommand)
        XCTAssertNil(opencodePR.resumeCommand)
        XCTAssertNil(geminiPrompt.resumeCommand)
        XCTAssertNil(rovoDevAuth.resumeCommand)
        XCTAssertNil(cursorPrint.resumeCommand)
        XCTAssertNil(copilotPrompt.resumeCommand)
        XCTAssertNil(codeBuddyPrint.resumeCommand)
        XCTAssertNil(factoryExec.resumeCommand)
        XCTAssertNil(qoderPrint.resumeCommand)
        XCTAssertNil(piExport.resumeCommand)
        XCTAssertNil(piInstall.resumeCommand)
    }

    /// Companion to the negative cases above: `pi --print "<prompt>"` is
    /// recorded by the cmux-vault TS bridge as a normal launch (pi's -p
    /// mode writes a session JSONL just like an interactive run), so on
    /// resume we strip --print and the trailing prompt positional, then
    /// re-inject `--session <id>`. Pins the e896b59 design choice.
    func testPiPrintLaunchIsRestoredAsInteractiveSession() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .pi,
            sessionId: "pi-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "pi",
                executablePath: "pi",
                arguments: ["pi", "--print", "summarize this"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let command = snapshot.resumeCommand
        XCTAssertNotNil(command)
        let display = command ?? "<nil>"
        XCTAssertTrue(
            display.contains("'pi' '--session' 'pi-session-123'"),
            "resume should re-inject --session <id>; got: \(display)"
        )
        XCTAssertFalse(
            display.contains("--print"),
            "resume must strip --print; got: \(display)"
        )
        XCTAssertFalse(
            display.contains("summarize this"),
            "resume must strip the prompt positional; got: \(display)"
        )
    }

    func testPiInteractiveLaunchProducesResumeCommand() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .pi,
            sessionId: "019dfabc-0001-7000-8000-000000000001",
            workingDirectory: "/tmp/pi-vault-test",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "pi",
                executablePath: "pi",
                arguments: [
                    "pi",
                    "--provider", "anthropic",
                    "--model", "claude-sonnet-4-5"
                ],
                workingDirectory: "/tmp/pi-vault-test",
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let command = snapshot.resumeCommand
        XCTAssertNotNil(command)
        let display = command ?? "<nil>"
        // Should `cd` into the working directory and re-launch pi with --session
        // re-injected, plus the user-set --provider/--model preserved verbatim.
        XCTAssertTrue(
            display.contains("cd '/tmp/pi-vault-test'"),
            "resume should cd into the recorded working directory; got: \(display)"
        )
        XCTAssertTrue(
            display.contains("'pi' '--session' '019dfabc-0001-7000-8000-000000000001'"),
            "resume should re-inject --session <full-uuid>; got: \(display)"
        )
        XCTAssertTrue(
            display.contains("'--provider' 'anthropic'"),
            "resume should preserve --provider; got: \(display)"
        )
        XCTAssertTrue(
            display.contains("'--model' 'claude-sonnet-4-5'"),
            "resume should preserve --model; got: \(display)"
        )
    }
}
