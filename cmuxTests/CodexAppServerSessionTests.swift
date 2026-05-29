import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct CodexAppServerSessionTests {
    @Test
    func testOpenCodeAuthHeaderMatchesServerEnvironment() {
        expectNil(OpenCodeServerAuth(environment: [:]))
        expectNil(OpenCodeServerAuth(environment: ["OPENCODE_SERVER_PASSWORD": ""]))

        expectEqual(
            OpenCodeServerAuth(environment: ["OPENCODE_SERVER_PASSWORD": "secret"])?.authorizationHeader,
            "Basic b3BlbmNvZGU6c2VjcmV0"
        )
        expectEqual(
            OpenCodeServerAuth(environment: [
                "OPENCODE_SERVER_USERNAME": "cmux",
                "OPENCODE_SERVER_PASSWORD": "secret",
            ])?.authorizationHeader,
            "Basic Y211eDpzZWNyZXQ="
        )
    }

    @Test
    func testOpenCodeEventStreamParserDecodesDataEvents() {
        var parser = OpenCodeEventStreamParser()

        expectEqual(parser.consumeLine("event: message").count, 0)
        expectEqual(parser.consumeLine(#"data: {"type":"server.connected","properties":{}}"#).count, 0)
        let events = parser.consumeLine("")

        expectEqual(events.count, 1)
        expectEqual(events.first?["type"] as? String, "server.connected")
    }

    @Test
    func testOpenCodeEventTextAccumulatorEmitsAssistantTextDeltasAfterRoleAndPartAreKnown() {
        var accumulator = OpenCodeEventTextAccumulator()

        expectEqual(
            accumulator.consumeEvent(
                [
                    "type": "message.part.delta",
                    "properties": [
                        "sessionID": "session-1",
                        "messageID": "message-1",
                        "partID": "part-1",
                        "field": "text",
                        "delta": "hel",
                    ],
                ], sessionID: "session-1"),
            []
        )
        expectEqual(
            accumulator.consumeEvent(
                [
                    "type": "message.part.updated",
                    "properties": [
                        "sessionID": "session-1",
                        "part": [
                            "id": "part-1",
                            "sessionID": "session-1",
                            "messageID": "message-1",
                            "type": "text",
                            "text": "hel",
                        ],
                    ],
                ], sessionID: "session-1"),
            []
        )
        expectEqual(
            accumulator.consumeEvent(
                [
                    "type": "message.updated",
                    "properties": [
                        "sessionID": "session-1",
                        "info": [
                            "id": "message-1",
                            "role": "assistant",
                        ],
                    ],
                ], sessionID: "session-1"),
            ["hel"]
        )
        expectEqual(
            accumulator.consumeEvent(
                [
                    "type": "message.part.delta",
                    "properties": [
                        "sessionID": "session-1",
                        "messageID": "message-1",
                        "partID": "part-1",
                        "field": "text",
                        "delta": "lo",
                    ],
                ], sessionID: "session-1"),
            ["lo"]
        )
    }

    @Test
    func testOpenCodeEventTextAccumulatorSkipsUserAndIgnoredText() {
        var accumulator = OpenCodeEventTextAccumulator()

        expectEqual(
            accumulator.consumeEvent(
                [
                    "type": "message.updated",
                    "properties": [
                        "sessionID": "session-1",
                        "info": [
                            "id": "message-1",
                            "role": "user",
                        ],
                    ],
                ], sessionID: "session-1"),
            []
        )
        expectEqual(
            accumulator.consumeEvent(
                [
                    "type": "message.part.updated",
                    "properties": [
                        "sessionID": "session-1",
                        "part": [
                            "id": "part-1",
                            "sessionID": "session-1",
                            "messageID": "message-1",
                            "type": "text",
                            "text": "do not echo",
                        ],
                    ],
                ], sessionID: "session-1"),
            []
        )
        expectEqual(
            accumulator.consumeEvent(
                [
                    "type": "message.updated",
                    "properties": [
                        "sessionID": "session-1",
                        "info": [
                            "id": "message-2",
                            "role": "assistant",
                        ],
                    ],
                ], sessionID: "session-1"),
            []
        )
        expectEqual(
            accumulator.consumeEvent(
                [
                    "type": "message.part.updated",
                    "properties": [
                        "sessionID": "session-1",
                        "part": [
                            "id": "part-2",
                            "sessionID": "session-1",
                            "messageID": "message-2",
                            "type": "text",
                            "text": "hidden",
                            "ignored": true,
                        ],
                    ],
                ], sessionID: "session-1"),
            []
        )
    }

    @Test
    func testOpenCodeEventTextAccumulatorAcceptsNestedSessionIDs() {
        var accumulator = OpenCodeEventTextAccumulator()

        expectEqual(
            accumulator.consumeEvent(
                [
                    "type": "message.part.updated",
                    "properties": [
                        "part": [
                            "id": "part-1",
                            "sessionID": "session-1",
                            "messageID": "message-1",
                            "type": "text",
                            "text": "nested",
                        ]
                    ],
                ], sessionID: "session-1"),
            []
        )
        expectEqual(
            accumulator.consumeEvent(
                [
                    "type": "message.updated",
                    "properties": [
                        "info": [
                            "id": "message-1",
                            "sessionID": "session-1",
                            "role": "assistant",
                        ]
                    ],
                ], sessionID: "session-1"),
            ["nested"]
        )
        expectEqual(
            accumulator.consumeEvent(
                [
                    "type": "message.part.delta",
                    "properties": [
                        "sessionID": "session-2",
                        "messageID": "message-1",
                        "partID": "part-1",
                        "field": "text",
                        "delta": "ignored",
                    ],
                ], sessionID: "session-1"),
            []
        )
    }

    @Test
    func testOpenCodeEventTextAccumulatorAcceptsPluginMessageFallbacks() {
        var accumulator = OpenCodeEventTextAccumulator()

        expectEqual(
            accumulator.consumeEvent(
                [
                    "type": "message.part.updated",
                    "properties": [
                        "part": [
                            "id": "part-1",
                            "sessionID": "session-1",
                            "messageID": "message-1",
                            "type": "text",
                            "textDelta": "fallback",
                        ]
                    ],
                ], sessionID: "session-1"),
            []
        )
        expectEqual(
            accumulator.consumeEvent(
                [
                    "type": "message.updated",
                    "properties": [
                        "message": [
                            "id": "message-1",
                            "sessionID": "session-1",
                            "role": "assistant",
                        ]
                    ],
                ], sessionID: "session-1"),
            ["fallback"]
        )
    }

    @Test
    func testOpenCodeEventTextAccumulatorAcceptsTopLevelMessageFallbacksAndPartContent() {
        var accumulator = OpenCodeEventTextAccumulator()

        expectEqual(
            accumulator.consumeEvent(
                [
                    "type": "message.updated",
                    "properties": [
                        "sessionID": "session-1",
                        "messageID": "message-1",
                        "role": "assistant",
                    ],
                ], sessionID: "session-1"),
            []
        )
        expectEqual(
            accumulator.consumeEvent(
                [
                    "type": "message.part.updated",
                    "properties": [
                        "part": [
                            "id": "part-1",
                            "sessionID": "session-1",
                            "messageID": "message-1",
                            "type": "text",
                            "content": "content fallback",
                        ]
                    ],
                ], sessionID: "session-1"),
            ["content fallback"]
        )
    }

    @Test
    func testClaudeStreamJSONAccumulatorExtractsAssistantTextDeltas() {
        var accumulator = ClaudeStreamJSONAccumulator()

        expectEqual(
            accumulator.consumeLine(#"{"type":"system","subtype":"init"}"#),
            []
        )
        expectEqual(
            accumulator.consumeLine(
                #"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"hello"}]}}"#
            ),
            ["hello"]
        )
        expectEqual(
            accumulator.consumeLine(
                #"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"hello world"}]}}"#
            ),
            [" world"]
        )
        expectEqual(
            accumulator.consumeLine(
                #"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"hello world"}]}}"#
            ),
            []
        )
    }

    @Test
    func testClaudeStreamJSONAccumulatorFallsBackToResultWhenNoAssistantTextArrived() {
        var accumulator = ClaudeStreamJSONAccumulator()

        expectEqual(
            accumulator.consumeLine(#"{"type":"result","subtype":"success","result":"done"}"#),
            ["done"]
        )
        expectEqual(
            accumulator.consumeLine(#"{"type":"result","subtype":"success","result":"done again"}"#),
            []
        )
    }

    @Test
    func testClaudeStreamJSONAccumulatorDoesNotDuplicateFinalAssistantMessageAfterDeltas() {
        var accumulator = ClaudeStreamJSONAccumulator()

        expectEqual(
            accumulator.consumeLine(
                #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"hel"}}"#),
            ["hel"]
        )
        expectEqual(
            accumulator.consumeLine(
                #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"lo"}}"#),
            ["lo"]
        )
        expectEqual(
            accumulator.consumeLine(
                #"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"hello world"}]}}"#
            ),
            [" world"]
        )
    }

    @Test
    func testClaudeStreamJSONAccumulatorTracksDeltaTextPerAssistantMessage() {
        var accumulator = ClaudeStreamJSONAccumulator()

        expectEqual(
            accumulator.consumeLine(
                #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"first"}}"#),
            ["first"]
        )
        expectEqual(
            accumulator.consumeLine(
                #"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"first done"}]}}"#
            ),
            [" done"]
        )
        expectEqual(
            accumulator.consumeLine(
                #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"second"}}"#),
            ["second"]
        )
        expectEqual(
            accumulator.consumeLine(
                #"{"type":"assistant","message":{"id":"msg_2","role":"assistant","content":[{"type":"text","text":"second done"}]}}"#
            ),
            [" done"]
        )
    }

    @Test
    func testEncodesPromptAsJSONRPCInsteadOfRawStdin() throws {
        var sentLines: [String] = []
        let session = CodexAppServerSession(
            workingDirectory: "/tmp/cmux-agent-session-test",
            writeData: { data in
                sentLines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            },
            outputSink: { _, _ in }
        )

        try session.start()
        expectEqual(jsonLine(sentLines[0])["method"] as? String, "initialize")

        session.consumeStdout(
            #"{"id":1,"result":{"userAgent":"codex","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}"#
                + "\n")
        expectEqual(jsonLine(sentLines[1])["method"] as? String, "initialized")

        let threadStart = jsonLine(sentLines[2])
        expectEqual(threadStart["method"] as? String, "thread/start")
        let threadParams = try #require(threadStart["params"] as? [String: Any])
        expectEqual(threadParams["cwd"] as? String, "/tmp/cmux-agent-session-test")

        try session.submit("hello codex", permissionMode: .fullAccess)
        expectEqual(sentLines.count, 3, "Prompt should queue until thread/start returns a thread id.")

        session.consumeStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"# + "\n")
        let turnStart = jsonLine(sentLines[3])
        expectEqual(turnStart["method"] as? String, "turn/start")
        let turnParams = try #require(turnStart["params"] as? [String: Any])
        expectEqual(turnParams["threadId"] as? String, "thread-1")
        expectEqual(turnParams["approvalPolicy"] as? String, "never")
        expectEqual(turnParams["approvalsReviewer"] as? String, "user")
        let sandboxPolicy = try #require(turnParams["sandboxPolicy"] as? [String: Any])
        expectEqual(sandboxPolicy["type"] as? String, "dangerFullAccess")
        let input = try #require(turnParams["input"] as? [[String: Any]])
        expectEqual(input.first?["type"] as? String, "text")
        expectEqual(input.first?["text"] as? String, "hello codex")

        for line in sentLines {
            expectTrue(line.hasPrefix("{"), "Codex app-server stdin must stay JSON-RPC, got \(line)")
        }
    }

    @Test
    func testAutoReviewPermissionModeAddsCodexReviewerOverride() throws {
        var sentLines: [String] = []
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { data in
                sentLines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            },
            outputSink: { _, _ in }
        )

        try session.start()
        session.consumeStdout(
            #"{"id":1,"result":{"userAgent":"codex","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}"#
                + "\n")
        session.consumeStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"# + "\n")
        try session.submit("please review", permissionMode: .autoReview)

        let turnStart = jsonLine(sentLines[3])
        expectEqual(turnStart["method"] as? String, "turn/start")
        let turnParams = try #require(turnStart["params"] as? [String: Any])
        expectEqual(turnParams["threadId"] as? String, "thread-1")
        expectEqual(turnParams["approvalPolicy"] as? String, "on-request")
        expectEqual(turnParams["approvalsReviewer"] as? String, "auto_review")
        expectNil(turnParams["sandboxPolicy"])
    }

    @Test
    func testMapsAgentMessageDeltaToStdout() {
        var output: [(String, String)] = []
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { _ in },
            outputSink: { stream, text in output.append((stream, text)) }
        )

        session.consumeStdout(
            #"{"method":"item/agentMessage/delta","params":{"delta":"partial answer"}}"# + "\n")

        expectEqual(output.count, 1)
        expectEqual(output.first?.0, "stdout")
        expectEqual(output.first?.1, "partial answer")
    }

    @Test
    func testCodexTurnCompletionNotificationMarksAssistantTurnComplete() {
        var completions = 0
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { _ in },
            outputSink: { _, _ in },
            turnCompleteSink: { completions += 1 }
        )

        session.consumeStdout(
            #"{"method":"turn/completed","params":{"threadId":"thread-1"}}"# + "\n")

        expectEqual(completions, 1)
    }

    @Test
    func testOpenCodeAssistantMessageCompletedTimeMarksTurnComplete() {
        let event: [String: Any] = [
            "type": "message.updated",
            "properties": [
                "sessionID": "opencode-session-1",
                "info": [
                    "id": "message-1",
                    "role": "assistant",
                    "time": [
                        "created": 1,
                        "completed": 2,
                    ],
                ],
            ],
        ]

        expectTrue(
            OpenCodeEventTextAccumulator.completesAssistantTurn(
                event,
                sessionID: "opencode-session-1"
            )
        )
        expectFalse(
            OpenCodeEventTextAccumulator.completesAssistantTurn(
                event,
                sessionID: "other-session"
            )
        )
    }

    @Test
    func testClaudeResultFrameMarksTurnComplete() {
        expectTrue(
            ClaudeStreamJSONAccumulator.completesAssistantTurn(
                #"{"type":"result","subtype":"success","result":"done"}"#
            )
        )
        expectFalse(
            ClaudeStreamJSONAccumulator.completesAssistantTurn(
                #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}"#
            )
        )
    }

    @Test
    func testDeclinedToolItemsDoNotRenderAsCompletedActivity() {
        var activities: [[String: Any]] = []
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { _ in },
            outputSink: { _, _ in },
            activitySink: { activity in activities.append(activity) }
        )

        session.consumeStdout(
            #"{"method":"item/completed","params":{"item":{"id":"cmd-1","type":"commandExecution","status":"declined","command":"dangerous command"}}}"#
                + "\n")
        session.consumeStdout(
            #"{"method":"item/completed","params":{"item":{"id":"file-1","type":"fileChange","status":"declined","changes":[{"path":"README.md","type":"update","diff":""}]}}}"#
                + "\n")

        expectEqual(activities.count, 2)
        expectEqual(activities[0]["kind"] as? String, "command")
        expectEqual(activities[0]["status"] as? String, "stopped")
        expectEqual(activities[0]["action"] as? String, "Stopped")
        expectEqual(activities[1]["kind"] as? String, "fileChange")
        expectEqual(activities[1]["status"] as? String, "stopped")
        expectEqual(activities[1]["action"] as? String, "Stopped")
    }

    @Test
    func testInitializeErrorFailsStartupAndRejectsLaterPrompts() throws {
        var sentLines: [String] = []
        var output: [(String, String)] = []
        var failures: [String?] = []
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { data in
                sentLines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            },
            outputSink: { stream, text in output.append((stream, text)) },
            failureSink: { details in failures.append(details) }
        )

        try session.start()
        try session.submit("queued prompt")
        session.consumeStdout(#"{"id":1,"error":{"message":"unsupported initialize"}}"# + "\n")

        expectEqual(sentLines.count, 1)
        expectEqual(failures.count, 1)
        expectEqual(failures.first!, "unsupported initialize")
        expectEqual(output.last?.0, "stderr")
        expectEqual(output.last?.1, "Codex app-server request failed.")
        expectThrowsError(try session.submit("later prompt"))
    }

    @Test
    func testThreadStartErrorClearsStartupStateAndRejectsLaterPrompts() throws {
        var sentLines: [String] = []
        var failures: [String?] = []
        let session = CodexAppServerSession(
            workingDirectory: "/tmp/cmux-missing-cwd",
            writeData: { data in
                sentLines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            },
            outputSink: { _, _ in },
            failureSink: { details in failures.append(details) }
        )

        try session.start()
        session.consumeStdout(#"{"id":1,"result":{}}"# + "\n")
        expectEqual(jsonLine(sentLines[2])["method"] as? String, "thread/start")

        try session.submit("queued prompt")
        session.consumeStdout(#"{"id":2,"error":{"message":"bad cwd"}}"# + "\n")

        expectEqual(failures.count, 1)
        expectEqual(failures.first!, "bad cwd")
        expectEqual(sentLines.count, 3)
        expectThrowsError(try session.submit("later prompt"))
    }

    private func jsonLine(_ rawLine: String) -> [String: Any] {
        guard let data = rawLine.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data),
            let object = decoded as? [String: Any]
        else {
            Issue.record("Expected JSON object")
            return [:]
        }
        return object
    }
}
