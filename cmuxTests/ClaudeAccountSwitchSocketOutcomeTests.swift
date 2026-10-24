import CMUXAgentLaunch
import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `claude_account.switch` replies come from one mapping. A switch that resumed reports the plan,
/// one that could not type the resume hands back the command cmux built, and every refusal has
/// its own error code.
struct ClaudeAccountSwitchSocketOutcomeTests {
    private let home = "/Users/cmux-test"
    private let sessionID = "a22293b7-bcef-4707-8439-2f538c8517a4"
    private let project = "/Users/cmux-test/project"
    private let surfaceId = UUID(uuidString: "6A1C2F7E-3B1D-4E55-9F0A-0C2B7D4E8F11")!

    @Test
    func resumedSwitchReportsThePlanAndTranscript() throws {
        let outcome = ClaudeAccountSwitchSocketOutcome.finished(.switched(try makePlan(to: "work"), .copied))

        #expect(outcome.controlCallResult(surfaceId: surfaceId, requestedAccountName: "work") == .ok(.object([
            "surface_id": .string(surfaceId.uuidString),
            "session_id": .string(sessionID),
            "from": .string(ClaudeAccountRegistry.defaultAccountName),
            "to": .string("work"),
            "transcript": .string("copied"),
            "resumed": .bool(true),
        ])))
    }

    @Test(arguments: [false, true])
    func switchWithoutResumeHandsBackTheBuiltCommand(paneWasReplaced: Bool) throws {
        let plan = try makePlan(to: ClaudeAccountRegistry.defaultAccountName, from: "\(home)/.claude-work")
        let manualResume = ClaudeAccountSwitchManualResume(
            command: "cd /Users/cmux-test/project && env -u CLAUDE_CONFIG_DIR claude --resume \(sessionID)",
            typedInput: "cd /Users/cmux-test/project && env -u CLAUDE_CONFIG_DIR claude --resume \(sessionID)\n",
            paneWasReplaced: paneWasReplaced
        )
        let outcome = ClaudeAccountSwitchSocketOutcome.finished(.switchedWithoutResume(plan, .refreshed, manualResume))

        #expect(outcome.controlCallResult(
            surfaceId: surfaceId,
            requestedAccountName: ClaudeAccountRegistry.defaultAccountName
        ) == .ok(.object([
            "surface_id": .string(surfaceId.uuidString),
            "session_id": .string(sessionID),
            "from": .string("work"),
            "to": .string(ClaudeAccountRegistry.defaultAccountName),
            "transcript": .string("refreshed"),
            "resumed": .bool(false),
            "resume_command": .string(manualResume.command),
            "pane_closed": .bool(paneWasReplaced),
        ])))
    }

    @Test
    func everyRefusalHasItsOwnErrorCode() {
        let cases: [(ClaudeAccountSwitchSocketOutcome, String)] = [
            (.finished(.refused(.unknownAccount("ghost"))), "unknown_account"),
            (.finished(.refused(.sameAccount("work"))), "same_account"),
            (.finished(.refused(.noClaudeSession)), "no_claude_session"),
            (.finished(.refused(.missingWorkingDirectory)), "missing_working_directory"),
            (.finished(.notClaude), "not_claude"),
            (.finished(.remoteUnsupported), "remote_unsupported"),
            (.finished(.alreadySwitching), "already_switching"),
            (.finished(.transcriptUnavailable), "transcript_unavailable"),
            (.finished(.respawnFailed), "respawn_failed"),
            (.agentRunning, "agent_running"),
        ]

        var messages: [String] = []
        for (outcome, expectedCode) in cases {
            guard case .err(let code, let message, let data) = outcome.controlCallResult(
                surfaceId: surfaceId,
                requestedAccountName: "work"
            ) else {
                Issue.record("\(outcome) did not map to an error")
                continue
            }
            #expect(code == expectedCode, "\(outcome)")
            #expect(!message.isEmpty, "\(outcome)")
            #expect(data == .object(["surface_id": .string(surfaceId.uuidString)]), "\(outcome)")
            messages.append(message)
        }
        #expect(Set(messages).count == cases.count)
    }

    @Test
    func refusalsExplainThemselvesLikeTheMenu() {
        // The socket and the menu share wording: the error message is the notice's explanation.
        let result = ClaudeAccountSwitchResult.refused(.unknownAccount("ghost"))
        let notice = ClaudeAccountSwitchNotice(result: result, requestedAccountName: "ghost")

        #expect(ClaudeAccountSwitchSocketOutcome.finished(result).controlCallResult(
            surfaceId: surfaceId,
            requestedAccountName: "ghost"
        ) == .err(
            code: "unknown_account",
            message: notice?.message ?? "",
            data: .object(["surface_id": .string(surfaceId.uuidString)])
        ))
    }

    private func makePlan(to target: String, from sourceConfigDirectory: String? = nil) throws -> ClaudeAccountSwitchPlan {
        let registry = ClaudeAccountRegistry(
            declarations: [ClaudeAccountDeclaration(name: "work", configDir: "~/.claude-work")],
            homeDirectory: home
        )
        return try ClaudeAccountSwitchPlanner.plan(
            sessionID: sessionID,
            workingDirectory: project,
            launchEnvironment: sourceConfigDirectory.map { ["CLAUDE_CONFIG_DIR": $0] },
            targetName: target,
            registry: registry,
            homeDirectory: home
        ).get()
    }
}
