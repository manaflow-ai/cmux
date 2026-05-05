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
    }
}
