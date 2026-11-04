import Darwin
import Foundation
import Testing

/// `cmux agent message` must go through `agent.message.send`, never the
/// terminal keystroke path, and the inbox hooks must answer each agent in the
/// shape its hook protocol expects without ever erasing a human's prompt.
@Suite(.serialized)
struct CLIAgentMessageCommandTests {
    static let callerWorkspaceID = "11111111-1111-1111-1111-111111111111"
    static let callerSurfaceID = "22222222-2222-2222-2222-222222222222"
    static let timeout: TimeInterval = 60

    // MARK: - cmux agent message

    @Test func messageGoesThroughTheMessageChannelNotKeystrokes() throws {
        let run = try runCLI(arguments: ["agent", "message", "cmux-remote-status", "rebase", "when", "free"])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let methods = run.requests.compactMap { $0["method"] as? String }
        #expect(methods.contains("agent.message.send"))
        #expect(!methods.contains("surface.send_text"))
        #expect(!methods.contains("terminal.paste"))
        let params = try #require(run.request("agent.message.send")?["params"] as? [String: Any])
        #expect(params["target"] as? String == "cmux-remote-status")
        #expect(params["body"] as? String == "rebase when free")
        #expect(params["sender_surface_id"] as? String == Self.callerSurfaceID)
        #expect(params["sender_workspace_id"] as? String == Self.callerWorkspaceID)
        #expect(params["from"] == nil)
        #expect(run.result.stdout.contains("msg-1"), Comment(rawValue: run.result.stdout))
    }

    @Test func messageFromThreadAndSeparator() throws {
        let run = try runCLI(arguments: [
            "agent", "message", "workspace:3", "--from", "reviewer", "--thread", "t-9", "--", "--not-a-flag",
        ])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let params = try #require(run.request("agent.message.send")?["params"] as? [String: Any])
        #expect(params["target"] as? String == "workspace:3")
        #expect(params["from"] as? String == "reviewer")
        #expect(params["thread_id"] as? String == "t-9")
        #expect(params["body"] as? String == "--not-a-flag")
    }

    @Test func replyToNeedsNoTarget() throws {
        let run = try runCLI(arguments: ["agent", "message", "--reply-to", "msg-0", "done"])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let params = try #require(run.request("agent.message.send")?["params"] as? [String: Any])
        #expect(params["reply_to"] as? String == "msg-0")
        #expect(params["target"] == nil)
        #expect(params["body"] as? String == "done")
    }

    @Test func dashReadsTheMessageFromStandardInput() throws {
        let run = try runCLI(
            arguments: ["agent", "message", "surface:4", "-"],
            standardInput: "line one\nline two\n"
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let params = try #require(run.request("agent.message.send")?["params"] as? [String: Any])
        #expect(params["body"] as? String == "line one\nline two\n")
    }

    @Test func emptyMessageFailsWithoutSending() throws {
        let run = try runCLI(arguments: ["agent", "message", "surface:4"], standardInput: "")

        #expect(run.result.status != 0)
        #expect(run.request("agent.message.send") == nil)
    }

    @Test func messageWarnsWhenTheRecipientHasNoAgentYet() throws {
        let run = try runCLI(
            arguments: ["agent", "message", "surface:4", "hi"],
            responses: ["agent.message.send": Self.sendResult(hasAgent: false)]
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        #expect(!run.result.stderr.isEmpty)
    }

    @Test func messagesOffDefaultsToTheCallersSurface() throws {
        let run = try runCLI(arguments: ["agent", "messages", "off"])
        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let params = try #require(run.request("agent.message.settings")?["params"] as? [String: Any])
        #expect(params["enabled"] as? Bool == false)
        #expect(params["scope"] as? String == "surface")
        #expect(params["surface_id"] as? String == Self.callerSurfaceID)
        #expect(params["target"] == nil)
    }

    @Test func messagesOnForAWorkspaceTargetAndStatusSetsNothing() throws {
        let on = try runCLI(arguments: ["agent", "messages", "on", "--workspace", "workspace:3"])
        let params = try #require(on.request("agent.message.settings")?["params"] as? [String: Any])
        #expect(params["enabled"] as? Bool == true)
        #expect(params["scope"] as? String == "workspace")
        #expect(params["target"] as? String == "workspace:3")
        let status = try runCLI(arguments: ["agent", "messages", "status", "surface:4"])
        let statusParams = try #require(status.request("agent.message.settings")?["params"] as? [String: Any])
        #expect(statusParams["enabled"] == nil)
        #expect(statusParams["target"] as? String == "surface:4")
    }

    @Test func statusSaysWhenTheSurfacesWorkspaceIsOff() throws {
        let settings: [String: Any] = [
            "scope": "surface", "id": "s", "ref": "surface:4", "workspace_title": "",
            "receiving": true, "messages_enabled": true, "failed": [String](), "workspace_receiving": false
        ]
        let run = try runCLI(arguments: ["agent", "messages", "status"], responses: ["agent.message.settings": settings])
        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        #expect(run.result.stdout.contains("Messages to surface:4 are on."))
        #expect(run.result.stdout.contains("Its workspace has messages off, so it receives none."))
    }

    @Test func messageHelpNeedsNoSocket() throws {
        let run = try runCLI(arguments: ["agent", "message", "--help"])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        #expect(run.result.stdout.contains("Usage: cmux agent message"))
        #expect(run.request("agent.message.send") == nil)
    }

    @Test func inboxListsMessagesAndCanMarkThemRead() throws {
        let run = try runCLI(
            arguments: ["agent", "inbox", "--surface", "workspace:2", "--state", "queued", "--mark-read"],
            responses: [
                "agent.message.list": [
                    "messages": [[
                        "id": "abcdef0123456789",
                        "state": "queued",
                        "sender_name": "coordinator",
                        "body": "first line\nsecond line",
                    ], [
                        "id": "fedcba9876543210",
                        "state": "queued",
                        "sender_name": "reviewer",
                        "body": "another message",
                    ]],
                ],
            ]
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let listParams = try #require(run.request("agent.message.list")?["params"] as? [String: Any])
        #expect(listParams["surface"] as? String == "workspace:2")
        #expect(listParams["state"] as? String == "queued")
        let readParams = try #require(run.request("agent.message.mark_read")?["params"] as? [String: Any])
        #expect(readParams["ids"] as? [String] == ["abcdef0123456789", "fedcba9876543210"])
        #expect(run.result.stdout.contains("abcdef01  coordinator: first line"), Comment(rawValue: run.result.stdout))
        #expect(run.result.stdout.contains("fedcba98  reviewer: another message"), Comment(rawValue: run.result.stdout))
        #expect(!run.result.stdout.contains("second line"))
    }

    // MARK: - Hooks

    @Test func claudePromptSubmitDrainAttachesPendingMessagesAsContext() throws {
        let run = try runCLI(
            arguments: ["hooks", "claude", "inbox-drain"],
            standardInput: #"{"session_id":"s-1","hook_event_name":"UserPromptSubmit","prompt":"hi"}"#,
            responses: ["agent.message.claim": ["messages": [], "text": "[cmux agent message] from a\n---\nhello\n---"]]
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        let params = try #require(run.request("agent.message.claim")?["params"] as? [String: Any])
        #expect(params["surface_id"] as? String == Self.callerSurfaceID)
        #expect(params["via"] as? String == "claude.prompt-submit")
        #expect(params["mark_delivered_read"] as? Bool == false)
        let output = try #require(codexHookJSONObject(run.result.stdout))
        let specific = try #require(output["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "UserPromptSubmit")
        #expect((specific["additionalContext"] as? String)?.contains("hello") == true)
    }

    @Test func claudePromptSubmitDrainIsANoOpWithoutMessages() throws {
        let run = try runCLI(
            arguments: ["hooks", "claude", "inbox-drain"],
            standardInput: #"{"session_id":"s-1"}"#,
            responses: ["agent.message.claim": ["messages": [], "text": ""]]
        )

        #expect(run.result.status == 0)
        #expect(run.result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "{}")
    }

    @Test func inboxHooksOutsideACmuxSurfaceDoNothing() throws {
        let run = try runCLI(
            arguments: ["hooks", "claude", "inbox-drain"],
            standardInput: #"{"session_id":"s-1"}"#,
            surfaceID: nil
        )

        #expect(run.result.status == 0)
        #expect(run.result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "{}")
        #expect(run.request("agent.message.claim") == nil)
    }

    @Test func claudeWaitClaimsThenWakesTheSessionByExitingTwo() throws {
        let run = try runCLI(
            arguments: ["hooks", "claude", "inbox-wait"],
            standardInput: #"{"session_id":"s-7","hook_event_name":"Stop"}"#,
            responses: [
                "agent.message.poll": ["status": "current", "queued": 1, "held": false],
                "agent.message.claim": ["messages": [], "lease_id": "lease-1", "text": "[cmux agent message] from a\n---\nwake up\n---"],
            ]
        )

        #expect(run.result.status == 2, Comment(rawValue: run.result.stderr))
        #expect(run.result.stderr.contains("wake up"), Comment(rawValue: run.result.stderr))
        #expect(run.result.stdout.isEmpty)
        let poll = try #require(run.request("agent.message.poll")?["params"] as? [String: Any])
        #expect(poll["surface_id"] as? String == Self.callerSurfaceID)
        #expect((poll["poller_key"] as? String)?.isEmpty == false)
        #expect(poll["register"] as? Bool == true)
        #expect(poll["mark_delivered_read"] as? Bool == true)
        let claim = try #require(run.request("agent.message.claim")?["params"] as? [String: Any])
        #expect(claim["via"] as? String == "claude.wake")
        #expect(claim["defer_delivery"] as? Bool == true)
        #expect((claim["poller_key"] as? String)?.isEmpty == false)
        let ack = try #require(run.request("agent.message.ack")?["params"] as? [String: Any])
        #expect(ack["surface_id"] as? String == Self.callerSurfaceID)
        #expect(ack["poller_key"] as? String == claim["poller_key"] as? String)
        #expect(ack["lease_id"] as? String == "lease-1")
        #expect(ack["via"] as? String == "claude.wake")
        // The poll claims nothing; the deferred claim is followed by an ack
        // after the message is handed to Claude.
        let methods = run.requests.compactMap { $0["method"] as? String }
        #expect(methods.firstIndex(of: "agent.message.poll")! < methods.firstIndex(of: "agent.message.claim")!)
        #expect(methods.firstIndex(of: "agent.message.claim")! < methods.firstIndex(of: "agent.message.ack")!)
    }

    @Test func claudeWaitExitsQuietlyWhenANewerHookTakesOver() throws {
        let run = try runCLI(
            arguments: ["hooks", "claude", "inbox-wait"],
            standardInput: #"{"session_id":"s-7","hook_event_name":"SessionStart"}"#,
            responses: ["agent.message.poll": ["status": "superseded"]]
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        #expect(run.result.stderr.isEmpty)
        let params = try #require(run.request("agent.message.poll")?["params"] as? [String: Any])
        #expect(params["mark_delivered_read"] as? Bool == false)
        #expect(run.request("agent.message.claim") == nil)
    }

    @Test func claudeWaitDoesNotClaimWhileDeliveryIsHeld() throws {
        // Held on every poll, then superseded, so the hook exits on its own.
        let run = try runCLI(
            arguments: ["hooks", "claude", "inbox-wait"],
            standardInput: #"{"session_id":"s-7","hook_event_name":"Stop"}"#,
            responses: ["agent.message.poll": ["status": "current", "queued": 2, "held": true]],
            pollResponsesAfterFirst: ["status": "superseded"]
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        #expect(run.request("agent.message.claim") == nil)
        let polls = run.requests.filter { $0["method"] as? String == "agent.message.poll" }
        #expect(polls.count == 2)
        #expect((polls.last?["params"] as? [String: Any])?["register"] as? Bool == false)
    }

    @Test func headlessClaudeRunsLeaveTheInboxAlone() throws {
        let drain = try runCLI(
            arguments: ["hooks", "claude", "inbox-drain"],
            standardInput: #"{"session_id":"s-1"}"#,
            extraEnvironment: ["CMUX_CLAUDE_HEADLESS": "1"],
            responses: ["agent.message.claim": ["messages": [], "text": "should not appear"]]
        )
        #expect(drain.result.status == 0)
        #expect(drain.result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "{}")

        let wait = try runCLI(
            arguments: ["hooks", "claude", "inbox-wait"],
            standardInput: #"{"session_id":"s-1","hook_event_name":"SessionStart"}"#,
            extraEnvironment: ["CMUX_CLAUDE_HEADLESS": "1"]
        )
        #expect(wait.result.status == 0)
        #expect(drain.requests.isEmpty && wait.requests.isEmpty)
    }

    @Test func optionsAndHelpFlagsAfterTheSeparatorAreMessageText() throws {
        let run = try runCLI(arguments: ["agent", "message", "surface:4", "--", "run", "ls", "-h", "--from", "x"])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        let params = try #require(run.request("agent.message.send")?["params"] as? [String: Any])
        #expect(params["target"] as? String == "surface:4")
        #expect(params["body"] as? String == "run ls -h --from x")
        #expect(params["from"] == nil)
    }

    @Test func codexStopContinuesTheTurnWithPendingMessages() throws {
        let run = try runCLI(
            arguments: ["hooks", "codex", "inbox-stop"],
            standardInput: #"{"session_id":"c-1","hook_event_name":"Stop"}"#,
            responses: ["agent.message.claim": ["messages": [], "text": "[cmux agent message] from a\n---\nnext\n---"]]
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        let params = try #require(run.request("agent.message.claim")?["params"] as? [String: Any])
        #expect(params["via"] as? String == "codex.stop")
        #expect(params["mark_delivered_read"] as? Bool == true)
        let output = try #require(codexHookJSONObject(run.result.stdout))
        #expect(output["decision"] as? String == "block")
        #expect((output["reason"] as? String)?.contains("next") == true)
    }
}
