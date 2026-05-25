import XCTest
@testable import CmuxKit

/// Tests that exercise `CMUXClient` against a stub transport. These verify
/// the exact shell-command shapes we send, JSON parsing of canonical
/// responses, and that error paths surface as typed `CmuxError`.
final class CMUXClientCommandTests: XCTestCase {

    func testListWorkspacesIssuesCorrectCommand() async throws {
        let transport = StubTransport()
        transport.oneShotResponses = [
            // First call: workspace.list
            .success(stdout: """
            {"window_id":"win-1","workspaces":[{"id":"ws-1","index":0,"title":"main","selected":true,"unread_count":2,"branch":"main"}]}
            """)
        ]
        let client = CMUXClient(transport: transport)
        let workspaces = try await client.listWorkspaces()
        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(workspaces.first?.id, WorkspaceID("ws-1"))
        XCTAssertEqual(workspaces.first?.title, "main")
        XCTAssertEqual(workspaces.first?.unreadCount, 2)
        XCTAssertEqual(workspaces.first?.branch, "main")
        XCTAssertTrue(transport.commandsIssued.first?.contains("rpc workspace.list") ?? false)
        XCTAssertFalse(transport.commandsIssued.first?.contains("--json") ?? true)
    }

    func testSendTextEscapesPayload() async throws {
        let transport = StubTransport()
        transport.oneShotResponses = [.success(stdout: "OK")]
        let client = CMUXClient(transport: transport)
        try await client.sendText("rm -rf $HOME", surfaceID: SurfaceID("sf-1"))
        let issued = try XCTUnwrap(transport.commandsIssued.first)
        // The dangerous payload must be inside single quotes so the remote
        // shell does not expand `$HOME` or re-interpret the spaces.
        XCTAssertTrue(issued.contains("'rm -rf $HOME'"),
                      "expected quoted payload, got: \(issued)")
        XCTAssertTrue(issued.contains("--surface sf-1"))
    }

    func testNonZeroExitMapsToCmuxError() async throws {
        let transport = StubTransport()
        transport.oneShotResponses = [
            .failure(exitCode: 2, stderr: "ERROR: Access denied")
        ]
        let client = CMUXClient(transport: transport)
        do {
            try await client.sendText("hello", surfaceID: SurfaceID("sf-1"))
            XCTFail("expected throw")
        } catch CmuxError.command(let exit, let stderr) {
            XCTAssertEqual(exit, 2)
            XCTAssertTrue(stderr.contains("Access denied"))
        } catch {
            XCTFail("expected CmuxError.command, got \(error)")
        }
    }

    func testEventStreamDecodesFramesThroughTransport() async throws {
        let transport = StubTransport()
        let frame1 = "{\"type\":\"ack\",\"boot_id\":\"B\",\"subscription_id\":\"S\",\"heartbeat_interval_seconds\":15,\"replay_count\":0,\"resume\":{\"gap\":false},\"filters\":{\"names\":[],\"categories\":[]}}"
        let frame2 = "{\"type\":\"event\",\"boot_id\":\"B\",\"seq\":1,\"id\":\"B-1\",\"name\":\"notification.created\",\"category\":\"notification\",\"source\":\"test\",\"occurred_at\":\"2026-05-22T12:00:00.000Z\",\"payload\":{}}"
        transport.lineStream = [frame1, frame2]
        let client = CMUXClient(transport: transport)
        var seen: [String] = []
        for try await frame in client.eventStream(cursor: CmuxEventCursor(bootID: "B", seq: 41)) {
            switch frame {
            case .ack: seen.append("ack")
            case .event(let event): seen.append(event.name)
            case .heartbeat: seen.append("hb")
            }
            if seen.count == 2 { break }
        }
        XCTAssertEqual(seen, ["ack", "notification.created"])
        // Confirm the cursor was forwarded as --after when seq was non-nil.
        XCTAssertTrue(transport.lineStreamCommand?.contains("events --reconnect") ?? false)
        XCTAssertTrue(transport.lineStreamCommand?.contains("--after 41") ?? false)
    }

    func testResolveChoiceDecisionUsesQuestionReplyWithSelectedLabel() async throws {
        let transport = StubTransport()
        transport.oneShotResponses = [.success(stdout: #"{"delivered":true}"#)]
        let client = CMUXClient(transport: transport)
        let decision = AgentDecision(
            id: "req-1",
            itemID: "807EB044-5EE6-442D-9C35-690956F5591F",
            workspaceID: nil,
            surfaceID: nil,
            agentName: "claude",
            kind: .choice,
            summary: "Pick one",
            detail: nil,
            choices: [
                .init(id: "ios", label: "iOS", style: .default, requiresAuth: false),
                .init(id: "ipad", label: "iPadOS", style: .default, requiresAuth: false)
            ],
            expiresAt: nil
        )
        _ = try await client.resolveAgentDecision(decision: decision, choiceID: "ipad")
        let issued = try XCTUnwrap(transport.commandsIssued.first)
        XCTAssertTrue(issued.contains("feed.question.reply"))
        XCTAssertTrue(issued.contains(#""request_id":"req-1""#))
        XCTAssertTrue(issued.contains(#""item_id":"807EB044-5EE6-442D-9C35-690956F5591F""#))
        XCTAssertTrue(issued.contains(#""selections":["iPadOS"]"#))
    }

    func testResolveExitPlanDecisionUsesExitPlanReply() async throws {
        let transport = StubTransport()
        transport.oneShotResponses = [.success(stdout: #"{"delivered":true}"#)]
        let client = CMUXClient(transport: transport)
        _ = try await client.resolveAgentDecision(
            decisionID: "plan-1",
            itemID: "7A81E448-5E76-4EDD-A428-FED75B26902E",
            kind: .exitPlan,
            choiceID: "auto_accept",
            choiceLabel: "Auto"
        )
        let issued = try XCTUnwrap(transport.commandsIssued.first)
        XCTAssertTrue(issued.contains("feed.exit_plan.reply"))
        XCTAssertTrue(issued.contains(#""item_id":"7A81E448-5E76-4EDD-A428-FED75B26902E""#))
        XCTAssertTrue(issued.contains(#""mode":"autoAccept""#))
    }

    func testResolveChoiceDecisionWithoutLabelUsesSelectionID() async throws {
        let transport = StubTransport()
        transport.oneShotResponses = [.success(stdout: #"{"delivered":true}"#)]
        let client = CMUXClient(transport: transport)
        _ = try await client.resolveAgentDecision(
            decisionID: "question-1",
            itemID: "ED12D035-9285-46C1-B431-83EB76611D8F",
            kind: .choice,
            choiceID: "ipad",
            choiceLabel: nil
        )
        let issued = try XCTUnwrap(transport.commandsIssued.first)
        XCTAssertTrue(issued.contains("feed.question.reply"))
        XCTAssertTrue(issued.contains(#""item_id":"ED12D035-9285-46C1-B431-83EB76611D8F""#))
        XCTAssertTrue(issued.contains(#""selection_ids":["ipad"]"#))
        XCTAssertFalse(issued.contains("selections"))
    }

    func testResolveChoiceDecisionWithQuestionSelectionsUsesItemBoundGroupedReply() async throws {
        let transport = StubTransport()
        transport.oneShotResponses = [.success(stdout: #"{"delivered":true}"#)]
        let client = CMUXClient(transport: transport)
        let decision = AgentDecision(
            id: "question-1",
            itemID: "9E8B9AD0-2957-4AA5-B0C2-AE7A48E07B78",
            workspaceID: nil,
            surfaceID: nil,
            agentName: "claude",
            kind: .choice,
            summary: "Pick defaults",
            detail: nil,
            choices: [
                .init(
                    id: "__cmux_defaults",
                    label: "Use defaults",
                    style: .affirmative,
                    requiresAuth: true,
                    questionSelections: [
                        .init(questionID: "target", optionIDs: ["yes"]),
                        .init(questionID: "risk", optionIDs: ["low"])
                    ]
                )
            ],
            expiresAt: nil
        )

        _ = try await client.resolveAgentDecision(decision: decision, choiceID: "__cmux_defaults")

        let issued = try XCTUnwrap(transport.commandsIssued.first)
        let payload = try XCTUnwrap(Self.jsonArgument(in: issued))
        XCTAssertEqual(payload["request_id"] as? String, "question-1")
        XCTAssertEqual(payload["item_id"] as? String, "9E8B9AD0-2957-4AA5-B0C2-AE7A48E07B78")
        XCTAssertNil(payload["selections"])
        let grouped = try XCTUnwrap(payload["question_selections"] as? [[String: Any]])
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped[0]["question_id"] as? String, "target")
        XCTAssertEqual(grouped[0]["option_ids"] as? [String], ["yes"])
        XCTAssertEqual(grouped[1]["question_id"] as? String, "risk")
        XCTAssertEqual(grouped[1]["option_ids"] as? [String], ["low"])
    }

    func testResolveDecisionThrowsWhenReplyIsNotDelivered() async throws {
        let transport = StubTransport()
        transport.oneShotResponses = [.success(stdout: #"{"delivered":false,"reason":"not_pending"}"#)]
        let client = CMUXClient(transport: transport)
        do {
            _ = try await client.resolveAgentDecision(
                decisionID: "stale-1",
                itemID: "63E09174-3317-4339-825B-E34B7CE97C8A",
                kind: .toolCall,
                choiceID: "allow",
                choiceLabel: "Allow once"
            )
            XCTFail("expected undelivered reply to throw")
        } catch CmuxError.command(let exitCode, let stderr) {
            XCTAssertEqual(exitCode, 0)
            XCTAssertTrue(stderr.contains("not_pending"))
        } catch {
            XCTFail("expected CmuxError.command, got \(error)")
        }
    }

    func testResolveUnknownPermissionChoiceThrowsInsteadOfAllowingOnce() async throws {
        let transport = StubTransport()
        let client = CMUXClient(transport: transport)
        do {
            _ = try await client.resolveAgentDecision(
                decisionID: "req-1",
                itemID: "81DF1790-7C06-406A-957D-E5D2DA1DE3B1",
                kind: .toolCall,
                choiceID: "new_allow_mode",
                choiceLabel: "New allow mode"
            )
            XCTFail("expected unknown choice to throw")
        } catch CmuxError.decoding(let message, _) {
            XCTAssertTrue(message.contains("unknown permission choice id"))
            XCTAssertTrue(transport.commandsIssued.isEmpty)
        }
    }

    func testResolveDecisionObjectWithoutItemIDThrowsWithoutIssuingCommand() async throws {
        let transport = StubTransport()
        let client = CMUXClient(transport: transport)
        let decision = AgentDecision(
            id: "req-unbound",
            workspaceID: nil,
            surfaceID: nil,
            agentName: "codex",
            kind: .toolCall,
            summary: "Run tool",
            detail: nil,
            choices: [
                .init(id: "allow", label: "Allow", style: .affirmative, requiresAuth: true),
                .init(id: "deny", label: "Deny", style: .destructive, requiresAuth: false)
            ],
            expiresAt: nil
        )

        do {
            _ = try await client.resolveAgentDecision(decision: decision, choiceID: "allow")
            XCTFail("expected missing item_id to throw")
        } catch CmuxError.decoding(let message, _) {
            XCTAssertTrue(message.contains("without item_id"))
            XCTAssertTrue(transport.commandsIssued.isEmpty)
        } catch {
            XCTFail("expected CmuxError.decoding, got \(error)")
        }
    }

    func testResolveNotificationDecisionWithoutItemIDThrowsWithoutIssuingCommand() async throws {
        let transport = StubTransport()
        let client = CMUXClient(transport: transport)

        do {
            _ = try await client.resolveAgentDecision(
                decisionID: "question-unbound",
                kind: .choice,
                choiceID: "ipad",
                choiceLabel: nil
            )
            XCTFail("expected missing item_id to throw")
        } catch CmuxError.decoding(let message, _) {
            XCTAssertTrue(message.contains("without item_id"))
            XCTAssertTrue(transport.commandsIssued.isEmpty)
        } catch {
            XCTFail("expected CmuxError.decoding, got \(error)")
        }
    }

    func testNewWorkspaceUsesWorkspaceCreateRPC() async throws {
        let transport = StubTransport()
        transport.oneShotResponses = [
            .success(stdout: #"{"workspace_id":"ws-2","window_id":"win-1","surface_id":"sf-1"}"#),
            .success(stdout: #"{"window_id":"win-1","workspaces":[{"id":"ws-2","index":1,"title":"New","selected":false,"unread_count":0}]}"#)
        ]
        let client = CMUXClient(transport: transport)
        let workspace = try await client.newWorkspace(cwd: "/tmp/project", command: "npm test")
        XCTAssertEqual(workspace?.id, WorkspaceID("ws-2"))
        let issued = try XCTUnwrap(transport.commandsIssued.first)
        XCTAssertTrue(issued.contains("rpc workspace.create"))
        XCTAssertTrue(issued.contains(#""cwd":"/tmp/project""#))
        XCTAssertTrue(issued.contains(#""initial_command":"npm test""#))
        XCTAssertFalse(issued.contains("new-workspace"))
    }

    func testListPendingAgentDecisionsUsesFeedListAndDecodesQuestionOptions() async throws {
        let transport = StubTransport()
        transport.oneShotResponses = [
            .success(stdout: """
            {
              "items": [
                {
                  "id": "805A443B-D68A-41F1-A8EF-8964465044B2",
                  "request_id": "q-1",
                  "workstream_id": "ws-feed-1",
                  "source": "claude",
                  "kind": "question",
                  "status": "pending",
                  "question_prompt": "Pick a target",
                  "question_options": [
                    {"id": "ios", "label": "iOS"},
                    {"id": "ipad", "label": "iPadOS"}
                  ]
                }
              ]
            }
            """)
        ]
        let client = CMUXClient(transport: transport)
        let decisions = try await client.listPendingAgentDecisions()
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.id, "q-1")
        XCTAssertEqual(decisions.first?.itemID, "805A443B-D68A-41F1-A8EF-8964465044B2")
        XCTAssertEqual(decisions.first?.kind, .choice)
        XCTAssertEqual(decisions.first?.choices.map(\.label), ["iOS", "iPadOS"])
        XCTAssertEqual(decisions.first?.choices.first?.requiresAuth, true)
        XCTAssertEqual(decisions.first?.choices.first?.questionSelections, [
            AgentDecision.QuestionSelection(questionID: "q0", optionIDs: ["ios"])
        ])
        let issued = try XCTUnwrap(transport.commandsIssued.first)
        XCTAssertTrue(issued.contains("rpc feed.list"))
        XCTAssertTrue(issued.contains(#""pending_only":true"#))
    }

    func testListPendingAgentDecisionsCollapsesMultiQuestionChoicesIntoGroupedDefault() async throws {
        let transport = StubTransport()
        transport.oneShotResponses = [
            .success(stdout: """
            {
              "items": [
                {
                  "id": "1640BCE4-0603-41DB-845B-5C84D5E20EF0",
                  "request_id": "q-multi",
                  "workstream_id": "ws-feed-1",
                  "source": "claude",
                  "kind": "question",
                  "status": "pending",
                  "question_prompt": "Pick defaults",
                  "questions": [
                    {
                      "id": "target",
                      "prompt": "Target?",
                      "options": [
                        {"id": "yes", "label": "iOS"},
                        {"id": "no", "label": "macOS"}
                      ]
                    },
                    {
                      "id": "risk",
                      "prompt": "Risk?",
                      "options": [
                        {"id": "yes", "label": "Low"},
                        {"id": "no", "label": "High"}
                      ]
                    }
                  ]
                }
              ]
            }
            """)
        ]
        let client = CMUXClient(transport: transport)
        let decisions = try await client.listPendingAgentDecisions()
        let decision = try XCTUnwrap(decisions.first)

        XCTAssertEqual(decision.itemID, "1640BCE4-0603-41DB-845B-5C84D5E20EF0")
        XCTAssertEqual(decision.choices.map(\.id), ["__cmux_defaults"])
        XCTAssertEqual(decision.choices.first?.questionSelections, [
            AgentDecision.QuestionSelection(questionID: "target", optionIDs: ["yes"]),
            AgentDecision.QuestionSelection(questionID: "risk", optionIDs: ["yes"])
        ])
    }

    func testListPendingAgentDecisionsDecodesDiffApprovalFromFeedList() async throws {
        let transport = StubTransport()
        transport.oneShotResponses = [
            .success(stdout: """
            {
              "items": [
                {
                  "id": "3F77B20C-7D86-40F0-BEB1-9290C542279A",
                  "request_id": "diff-1",
                  "workstream_id": "ws-feed-1",
                  "source": "codex",
                  "kind": "permissionRequest",
                  "status": "pending",
                  "hook_event_name": "DiffApprovalRequest",
                  "decision_kind": "diff",
                  "tool_input": "diff --git a/file b/file"
                }
              ]
            }
            """)
        ]
        let client = CMUXClient(transport: transport)
        let decisions = try await client.listPendingAgentDecisions()
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.id, "diff-1")
        XCTAssertEqual(decisions.first?.itemID, "3F77B20C-7D86-40F0-BEB1-9290C542279A")
        XCTAssertEqual(decisions.first?.kind, .diff)
        XCTAssertEqual(decisions.first?.choices.map(\.id), ["apply", "reject"])
    }

    func testBrowserGotoUsesPositionalURL() async throws {
        let transport = StubTransport()
        transport.oneShotResponses = [.success(stdout: "OK")]
        let client = CMUXClient(transport: transport)
        _ = try await client.browserGoto(URL(string: "https://example.com/path")!, surfaceID: SurfaceID("sf-1"))
        let issued = try XCTUnwrap(transport.commandsIssued.first)
        XCTAssertTrue(issued.contains("browser goto"))
        XCTAssertTrue(issued.contains("--surface sf-1"))
        XCTAssertFalse(issued.contains("--url"))
        XCTAssertTrue(issued.contains("https://example.com/path"))
    }

    func testBrowserGotoThrowsOnNonZeroExit() async throws {
        let transport = StubTransport()
        transport.oneShotResponses = [.failure(exitCode: 7, stderr: "browser surface missing")]
        let client = CMUXClient(transport: transport)
        do {
            _ = try await client.browserGoto(URL(string: "https://example.com")!, surfaceID: SurfaceID("sf-missing"))
            XCTFail("expected browser command failure")
        } catch CmuxError.command(let exitCode, let stderr) {
            XCTAssertEqual(exitCode, 7)
            XCTAssertTrue(stderr.contains("surface missing"))
        } catch {
            XCTFail("expected CmuxError.command, got \(error)")
        }
    }
}

private extension CMUXClientCommandTests {
    static func jsonArgument(in command: String) -> [String: Any]? {
        guard let start = command.firstIndex(of: "{"),
              let end = command.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        let json = String(command[start...end])
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

// MARK: - Stub transport

private final class StubTransport: CmuxSSHTransport, @unchecked Sendable {
    enum Response {
        case success(stdout: String)
        case failure(exitCode: Int32, stderr: String)
    }

    var oneShotResponses: [Response] = []
    var commandsIssued: [String] = []
    var lineStream: [String] = []
    var lineStreamCommand: String?

    func runOneShot(command: String, stdin: Data?) async throws -> CmuxExecResult {
        commandsIssued.append(command)
        guard !oneShotResponses.isEmpty else {
            return CmuxExecResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let response = oneShotResponses.removeFirst()
        switch response {
        case .success(let stdout):
            return CmuxExecResult(exitCode: 0, stdout: Data(stdout.utf8), stderr: Data())
        case .failure(let exit, let stderr):
            return CmuxExecResult(exitCode: exit, stdout: Data(), stderr: Data(stderr.utf8))
        }
    }

    func runLineStream(
        command: String,
        onStderrLine: @Sendable @escaping (String) -> Void
    ) -> AsyncThrowingStream<String, any Error> {
        lineStreamCommand = command
        let lines = lineStream
        return AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }

    func runByteStream(
        command: String,
        onStderrLine: @Sendable @escaping (String) -> Void
    ) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }

    func ping() async throws -> Duration { .zero }
    func close() async {}
}
