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
            "not_resumed_reason": .string(paneWasReplaced ? "pane_closed" : "no_prompt"),
        ])))
    }

    @Test
    func switchWhilePreviousClaudeStillRunsSaysWhyItDidNotResume() throws {
        let plan = try makePlan(to: "work")
        let manualResume = ClaudeAccountSwitchManualResume(
            command: "cd /Users/cmux-test/project && claude --resume \(sessionID)",
            typedInput: "x\n",
            reason: .previousClaudeStillRunning(processIDs: [48_213])
        )
        let outcome = ClaudeAccountSwitchSocketOutcome.finished(.switchedWithoutResume(plan, .refreshed, manualResume))

        guard case .ok(.object(let payload)) = outcome.controlCallResult(surfaceId: surfaceId, requestedAccountName: "work") else {
            Issue.record("a switch whose resume was held back still succeeds")
            return
        }
        #expect(payload["resumed"] == .bool(false))
        #expect(payload["pane_closed"] == .bool(false))
        #expect(payload["not_resumed_reason"] == .string("previous_claude_running"))
        #expect(payload["resume_command"] == .string(manualResume.command))
        // The socket path posts it as a notification, since the caller may have died with the pane.
        #expect(outcome.resumeNotification?.body.contains("48213") == true)
    }

    @Test
    func everyRefusalHasItsOwnErrorCode() {
        let cases: [(ClaudeAccountSwitchSocketOutcome, String)] = [
            (.finished(.refused(.unknownAccount("ghost"))), "unknown_account"),
            (.finished(.refused(.sameAccount("work"))), "same_account"),
            (.finished(.refused(.noClaudeSession)), "no_claude_session"),
            (.finished(.refused(.missingWorkingDirectory)), "missing_working_directory"),
            (.finished(.refused(.noConversationYet)), "no_conversation_yet"),
            (.finished(.refused(.transcriptDiverged(newerAccount: "work"))), "transcript_diverged"),
            (.finished(.notClaude), "not_claude"),
            (.finished(.remoteUnsupported), "remote_unsupported"),
            (.finished(.agentNotOwnedByPane), "agent_not_owned_by_pane"),
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

    @Test(arguments: [false, true])
    func switchWithoutResumePostsTheBuiltCommandAsANotification(paneWasReplaced: Bool) throws {
        // The CLI that asked may have run in the respawned pane and died with it, so the reply
        // alone can be lost; the notification carries the same command.
        let plan = try makePlan(to: "work")
        let manualResume = ClaudeAccountSwitchManualResume(
            command: "cd /Users/cmux-test/project && CLAUDE_CONFIG_DIR=/Users/cmux-test/.claude-work claude --resume \(sessionID)",
            typedInput: "x\n",
            paneWasReplaced: paneWasReplaced
        )
        let result = ClaudeAccountSwitchResult.switchedWithoutResume(plan, .copied, manualResume)
        let notice = try #require(ClaudeAccountSwitchNotice(result: result, requestedAccountName: "work"))

        let notification = try #require(ClaudeAccountSwitchSocketOutcome.finished(result).resumeNotification)

        // Compared with the same catalog lookups, so the suite holds in every locale.
        #expect(notification.title == String(
            localized: "notification.claudeAccountSwitch.title",
            defaultValue: "Claude account switched"
        ))
        #expect(notification.subtitle == notice.title)
        #expect(notification.body.contains(manualResume.command))
        #expect(notification.body == notice.notificationMessage)
        // A notification has no Type Resume Command button, so it never points at one.
        let typeResumeButton = String(
            localized: "dialog.claudeAccountSwitch.typeResumeCommand",
            defaultValue: "Type Resume Command"
        )
        #expect(!notification.body.contains(typeResumeButton))
        if !paneWasReplaced {
            // The alert for the same result does name it, so the check above is not vacuous.
            #expect(notice.message.contains(typeResumeButton))
        }
        if paneWasReplaced {
            #expect(notification.body == notice.message)
        }
    }

    @Test
    func onlyASwitchWithoutResumePostsANotification() throws {
        let outcomes: [ClaudeAccountSwitchSocketOutcome] = [
            .finished(.switched(try makePlan(to: "work"), .copied)),
            .finished(.refused(.unknownAccount("ghost"))),
            .finished(.notClaude),
            .finished(.respawnFailed),
            .agentRunning,
        ]

        #expect(outcomes.allSatisfy { $0.resumeNotification == nil })
    }

    @Test
    @MainActor
    func theNotificationFallsBackToTheWorkspaceWhenThePaneIsGone() {
        let workspaceId = UUID()
        let notification = ClaudeAccountSwitchSocketOutcome.ResumeNotification(title: "t", subtitle: "s", body: "b")
        var deliveries: [UUID?] = []

        let paneGone = notification.post(workspaceId: workspaceId, panelId: surfaceId, paneIsLive: false) {
            tabId, surface, title, subtitle, body in
            #expect(tabId == workspaceId && title == "t" && subtitle == "s" && body == "b")
            deliveries.append(surface)
            return UUID()
        }
        #expect(paneGone != nil)
        #expect(deliveries == [nil])

        deliveries = []
        let paneThere = notification.post(workspaceId: workspaceId, panelId: surfaceId, paneIsLive: true) {
            _, surface, _, _, _ in
            deliveries.append(surface)
            return UUID()
        }
        #expect(paneThere != nil)
        #expect(deliveries == [surfaceId])
    }

    /// With notification hooks configured, recording a notification on a live pane is deferred
    /// and returns no id yet. That is not "the pane is gone": a second, workspace-level copy
    /// would show the same notification twice.
    @Test
    @MainActor
    func aDeferredDeliveryOnALivePaneIsNotPostedTwice() {
        let workspaceId = UUID()
        let notification = ClaudeAccountSwitchSocketOutcome.ResumeNotification(title: "t", subtitle: "s", body: "b")
        var deliveries: [UUID?] = []

        notification.post(workspaceId: workspaceId, panelId: surfaceId, paneIsLive: true) { _, surface, _, _, _ in
            deliveries.append(surface)
            return nil
        }

        #expect(deliveries == [surfaceId])
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
