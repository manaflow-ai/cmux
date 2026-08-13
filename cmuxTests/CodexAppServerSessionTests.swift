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
    private func expectThrowsErrorAsync<T>(
        _ expression: () async throws -> T,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        do {
            _ = try await expression()
            Issue.record("Expected expression to throw", sourceLocation: sourceLocation)
        } catch {
        }
    }

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
    func testOpenCodeEventStreamParserBoundsUnterminatedDataEvents() {
        var parser = OpenCodeEventStreamParser()

        expectEqual(parser.consumeLine("data: \(String(repeating: "a", count: 1024 * 1024 + 1))").count, 0)
        expectEqual(parser.consumeLine("").count, 0)
        expectEqual(parser.consumeLine(#"data: {"type":"server.connected","properties":{}}"#).count, 0)

        let events = parser.consumeLine("")

        expectEqual(events.count, 1)
        expectEqual(events.first?["type"] as? String, "server.connected")
    }

    @Test
    func testAgentSessionOutputLineBufferBoundsNewlineFreeOutput() {
        var buffer = AgentSessionOutputLineBuffer()
        let oversizedLine = Data(repeating: 97, count: 2 * 1024 * 1024 + 5)

        let lines = buffer.append(oversizedLine)

        expectEqual(lines.count, 2)
        expectTrue(lines.allSatisfy { $0.hasSuffix("\n") })
        expectTrue(lines.allSatisfy { $0.count <= 1024 * 1024 + 1 })
        expectEqual(buffer.bufferedByteCountForTesting, 5)
        expectEqual(buffer.flush(), [String(repeating: "a", count: 5)])
    }

    @Test
    func testAgentSessionOutputLineBufferPreservesNormalNewlineFrames() {
        var buffer = AgentSessionOutputLineBuffer()

        expectEqual(buffer.append(Data("hello\npartial".utf8)), ["hello\n"])
        expectEqual(buffer.bufferedByteCountForTesting, "partial".utf8.count)
        expectEqual(buffer.append(Data(" line\n".utf8)), ["partial line\n"])
        expectEqual(buffer.flush(), [])
    }

    @Test
    func testOpenCodeProcessStdoutLogsAreNotAssistantOutput() throws {
        let serverURL = try #require(URL(string: "http://127.0.0.1:49211"))

        expectEqual(
            AgentSessionProcessStore.openCodeProcessOutputDisposition(
                text: "opencode server listening on http://127.0.0.1:49211\n",
                stream: "stdout"
            ),
            .serverURL(serverURL)
        )
        expectEqual(
            AgentSessionProcessStore.openCodeProcessOutputDisposition(
                text: "INFO request completed\n",
                stream: "stdout"
            ),
            .suppress
        )
        expectEqual(
            AgentSessionProcessStore.openCodeProcessOutputDisposition(
                text: "OpenCode session could not be created.\n",
                stream: "stderr"
            ),
            .emit
        )
    }

    @Test
    func testOpenCodeEventStreamEOFPolicyFailsOnlyForLiveSession() {
        expectTrue(
            AgentSessionProcessStore.openCodeEventStreamEOFRequiresFailure(
                isCancelled: false,
                processIsRunning: true
            )
        )
        expectFalse(
            AgentSessionProcessStore.openCodeEventStreamEOFRequiresFailure(
                isCancelled: true,
                processIsRunning: true
            )
        )
        expectFalse(
            AgentSessionProcessStore.openCodeEventStreamEOFRequiresFailure(
                isCancelled: false,
                processIsRunning: false
            )
        )
    }

    @Test
    func testCodexMcpElicitationSchemaSupportFailsClosed() {
        expectTrue(AgentSessionProcessStore.mcpElicitationIsSupported([
            "mode": "openai/form",
            "requestedSchema": [
                "type": "object",
                "properties": [
                    "target": ["type": "string", "enum": ["iOS", "macOS"]],
                    "confirm": ["type": "boolean"],
                    "count": ["type": "integer", "minimum": 1, "maximum": 5],
                    "named": [
                        "type": "string",
                        "oneOf": [
                            ["const": "a", "title": "Alpha"],
                            ["const": "b", "title": "Beta"],
                        ],
                    ],
                    "tags": [
                        "type": "array",
                        "items": [
                            "anyOf": [
                                ["const": "a", "title": "Alpha"],
                                ["const": "b", "title": "Beta"],
                            ],
                        ],
                        "minItems": 1,
                        "maxItems": 2,
                    ],
                ],
            ],
        ]))
        expectTrue(AgentSessionProcessStore.mcpElicitationIsSupported([
            "mode": "url",
            "url": "https://example.com/approve",
        ]))
        expectFalse(AgentSessionProcessStore.mcpElicitationIsSupported([
            "mode": "openai/form",
            "requestedSchema": [
                "type": "object",
                "properties": ["nested": ["type": "object"]],
            ],
        ]))
        expectFalse(AgentSessionProcessStore.mcpElicitationIsSupported([
            "mode": "url",
            "url": "javascript:alert(1)",
        ]))
        expectFalse(AgentSessionProcessStore.mcpElicitationIsSupported([
            "mode": "form",
            "requestedSchema": [
                "type": "object",
                "properties": ["bad": ["type": "string", "minLength": 5, "maxLength": 2]],
            ],
        ]))
    }

    @Test
    func testCodexMcpToolApprovalUsesPermissionDecisions() throws {
        let params: [String: Any] = [
            "message": "Allow the tool?",
            "_meta": ["codex_approval_kind": "mcp_tool_call"],
        ]
        expectTrue(AgentSessionProcessStore.isMCPToolApproval(params))

        let accepted = AgentSessionProcessStore.codexResolution(
            .init(result: .resolved(itemId: nil, decision: .permission(.once)), authoritativeEvent: nil),
            method: "mcpServer/elicitation/request",
            params: params
        )
        guard case .result(let acceptedJSON) = accepted else {
            Issue.record("expected an accepted MCP approval response")
            return
        }
        let acceptedObject = try #require(
            JSONSerialization.jsonObject(with: Data(acceptedJSON.utf8)) as? [String: Any]
        )
        expectEqual(acceptedObject["action"] as? String, "accept")
        #expect(acceptedObject["content"] is [String: Any])

        for (mode, scope) in [
            (WorkstreamPermissionMode.always, "session"),
            (.persistent, "always"),
        ] {
            let resolution = AgentSessionProcessStore.codexResolution(
                .init(result: .resolved(itemId: nil, decision: .permission(mode)), authoritativeEvent: nil),
                method: "mcpServer/elicitation/request",
                params: params
            )
            guard case .result(let json) = resolution,
                  let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                Issue.record("expected a persistent MCP approval response")
                continue
            }
            expectEqual(object["action"] as? String, "accept")
            expectEqual((object["_meta"] as? [String: Any])?["persist"] as? String, scope)
        }

        let denied = AgentSessionProcessStore.codexResolution(
            .init(result: .resolved(itemId: nil, decision: .permission(.deny)), authoritativeEvent: nil),
            method: "mcpServer/elicitation/request",
            params: params
        )
        guard case .result(let deniedJSON) = denied else {
            Issue.record("expected a declined MCP approval response")
            return
        }
        let deniedObject = try #require(
            JSONSerialization.jsonObject(with: Data(deniedJSON.utf8)) as? [String: Any]
        )
        expectEqual(deniedObject["action"] as? String, "decline")
        #expect(deniedObject["content"] is NSNull)
    }

    @Test
    func testCodexMcpFormResolutionPreservesSchemaTypesAndEnumValues() throws {
        let params: [String: Any] = [
            "requestedSchema": [
                "type": "object",
                "properties": [
                    "confirm": ["type": "boolean"],
                    "count": ["type": "integer"],
                    "ratio": ["type": "number"],
                    "target": ["type": "string", "enum": ["iOS", "macOS"]],
                    "tags": [
                        "type": "array",
                        "items": ["type": "string", "enum": ["fast", "safe"]],
                    ],
                ],
            ],
        ]
        let resolution = AgentSessionProcessStore.codexResolution(
            .init(
                result: .resolved(
                    itemId: nil,
                    decision: .question(selections: [
                        "confirm=true",
                        "count=3",
                        "ratio=1.5",
                        "target=opt1",
                        "tags=opt0",
                        "tags=opt1",
                    ])
                ),
                authoritativeEvent: nil
            ),
            method: "mcpServer/elicitation/request",
            params: params
        )

        guard case .result(let json) = resolution else {
            Issue.record("expected an accepted MCP form response")
            return
        }
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        expectEqual(object["action"] as? String, "accept")
        let content = try #require(object["content"] as? [String: Any])
        expectEqual(content["confirm"] as? Bool, true)
        expectEqual(content["count"] as? Int, 3)
        expectEqual(content["ratio"] as? Double, 1.5)
        expectEqual(content["target"] as? String, "macOS")
        expectEqual(content["tags"] as? [String], ["fast", "safe"])
    }

    @Test
    func testCodexMcpTitledEnumsAndExplicitFormActions() throws {
        let params: [String: Any] = [
            "requestedSchema": [
                "type": "object",
                "properties": [
                    "target": [
                        "type": "string",
                        "oneOf": [
                            ["const": "ios", "title": "iOS"],
                            ["const": "mac", "title": "macOS"],
                        ],
                    ],
                    "tags": [
                        "type": "array",
                        "items": [
                            "anyOf": [
                                ["const": "fast", "title": "Fast"],
                                ["const": "safe", "title": "Safe"],
                            ],
                        ],
                    ],
                ],
            ],
        ]
        let accepted = AgentSessionProcessStore.codexResolution(
            .init(
                result: .resolved(
                    itemId: nil,
                    decision: .form(
                        action: .accept,
                        selections: ["target=mac", "tags=fast", "tags=safe"]
                    )
                ),
                authoritativeEvent: nil
            ),
            method: "mcpServer/elicitation/request",
            params: params
        )
        guard case .result(let acceptedJSON) = accepted else {
            Issue.record("expected an accepted MCP form response")
            return
        }
        let acceptedObject = try #require(
            JSONSerialization.jsonObject(with: Data(acceptedJSON.utf8)) as? [String: Any]
        )
        expectEqual(acceptedObject["action"] as? String, "accept")
        let content = try #require(acceptedObject["content"] as? [String: Any])
        expectEqual(content["target"] as? String, "mac")
        expectEqual(content["tags"] as? [String], ["fast", "safe"])

        for action in [WorkstreamFormAction.decline, .cancel] {
            let resolution = AgentSessionProcessStore.codexResolution(
                .init(
                    result: .resolved(
                        itemId: nil,
                        decision: .form(action: action, selections: [])
                    ),
                    authoritativeEvent: nil
                ),
                method: "mcpServer/elicitation/request",
                params: params
            )
            guard case .result(let json) = resolution,
                  let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                Issue.record("expected an explicit MCP form response")
                continue
            }
            expectEqual(object["action"] as? String, action.rawValue)
            #expect(object["content"] is NSNull)
        }
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
    func testOpenCodeEventTextAccumulatorStreamsAfterEmptyTextPartAnnouncement() {
        var accumulator = OpenCodeEventTextAccumulator()

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
                            "text": "",
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
            []
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
                        "delta": "hello",
                    ],
                ], sessionID: "session-1"),
            ["hello"]
        )
        expectEqual(accumulator.retainedTextCharacterCountForTesting, 0)
    }

    @Test
    func testOpenCodeEventTextAccumulatorPreservesAssistantTextWhitespace() {
        var accumulator = OpenCodeEventTextAccumulator()

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
                            "text": "  indented code\n",
                        ],
                    ],
                ], sessionID: "session-1"),
            ["  indented code\n"]
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
                            "text": "  indented code\n   ",
                        ],
                    ],
                ], sessionID: "session-1"),
            ["   "]
        )
    }

    @Test
    func testOpenCodeEventTextAccumulatorContinuesAfterRetainedFullTextIsBounded() {
        var accumulator = OpenCodeEventTextAccumulator()
        let prefix = String(repeating: "a", count: 256 * 1024)

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
            []
        )
        let firstOversizedOutput = accumulator.consumeEvent(
            [
                "type": "message.part.updated",
                "properties": [
                    "sessionID": "session-1",
                    "part": [
                        "id": "part-1",
                        "sessionID": "session-1",
                        "messageID": "message-1",
                        "type": "text",
                        "text": prefix + "A",
                    ],
                ],
            ], sessionID: "session-1"
        )
        expectEqual(
            firstOversizedOutput.first.map { String($0.suffix(1)) },
            Optional("A")
        )
        expectEqual(accumulator.retainedTextCharacterCountForTesting, 256 * 1024)
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
                            "text": prefix + "AB",
                        ],
                    ],
                ], sessionID: "session-1"),
            ["B"]
        )
        expectEqual(accumulator.retainedTextCharacterCountForTesting, 256 * 1024)
    }

    @Test
    func testOpenCodeEventTextAccumulatorPrunesCompletedAssistantMessages() {
        var accumulator = OpenCodeEventTextAccumulator()

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
                            "text": String(repeating: "a", count: 1024),
                        ],
                    ],
                ], sessionID: "session-1").first?.count,
            1024
        )
        expectEqual(accumulator.retainedTextCharacterCountForTesting, 1024)
        expectEqual(
            accumulator.consumeEvent(
                [
                    "type": "message.updated",
                    "properties": [
                        "sessionID": "session-1",
                        "info": [
                            "id": "message-1",
                            "role": "assistant",
                            "time": ["completed": "2026-06-05T00:00:00Z"],
                        ],
                    ],
                ], sessionID: "session-1"),
            []
        )
        expectEqual(accumulator.retainedTextCharacterCountForTesting, 0)
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
    func testClaudeStreamJSONAccumulatorPrunesTurnStateOnCompletion() {
        var accumulator = ClaudeStreamJSONAccumulator()

        expectEqual(
            accumulator.consumeLine(
                #"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"hello"}]}}"#
            ),
            ["hello"]
        )
        expectEqual(accumulator.retainedTextCharacterCountForTesting, 0)
        expectEqual(accumulator.consumeLine(#"{"type":"message_stop"}"#), [])
        expectEqual(accumulator.retainedTextCharacterCountForTesting, 0)
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
    func testEncodesPromptAsJSONRPCInsteadOfRawStdin() async throws {
        var sentLines: [String] = []
        let session = CodexAppServerSession(
            workingDirectory: "/tmp/cmux-agent-session-test",
            writeData: { data in
                sentLines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            },
            outputSink: { _, _ in }
        )

        try await session.start()
        let initialize = jsonLine(sentLines[0])
        expectEqual(initialize["method"] as? String, "initialize")
        let initializeParams = try #require(initialize["params"] as? [String: Any])
        let capabilities = try #require(initializeParams["capabilities"] as? [String: Any])
        expectEqual(capabilities["mcpServerOpenaiFormElicitation"] as? Bool, true)
        let extensions = try #require(capabilities["extensions"] as? [String: Any])
        #expect(extensions["openai/form"] is [String: Any])

        session.consumeStdout(
            #"{"id":1,"result":{"userAgent":"codex","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}"#
                + "\n")
        await Task.yield()
        expectEqual(jsonLine(sentLines[1])["method"] as? String, "initialized")

        let threadStart = jsonLine(sentLines[2])
        expectEqual(threadStart["method"] as? String, "thread/start")
        let threadParams = try #require(threadStart["params"] as? [String: Any])
        expectEqual(threadParams["cwd"] as? String, "/tmp/cmux-agent-session-test")

        let submitTask = Task { try await session.submit("hello codex", permissionMode: .fullAccess) }
        expectEqual(sentLines.count, 3, "Prompt should queue until thread/start returns a thread id.")

        session.consumeStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"# + "\n")
        try await submitTask.value
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
    func testCodexInputQueueBeforeThreadIsBounded() async throws {
        var sentLines: [String] = []
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { data in
                sentLines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            },
            outputSink: { _, _ in }
        )

        try await session.start()
        let submitTask = Task { try await session.submit("first prompt") }
        await expectThrowsErrorAsync {
            try await session.submit("second prompt")
        }

        session.consumeStdout(
            #"{"id":1,"result":{"userAgent":"codex","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}"#
                + "\n")
        await Task.yield()
        session.consumeStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"# + "\n")
        try await submitTask.value

        expectEqual(sentLines.count, 4)
        let turnStart = jsonLine(sentLines[3])
        expectEqual(turnStart["method"] as? String, "turn/start")
        let turnParams = try #require(turnStart["params"] as? [String: Any])
        let input = try #require(turnParams["input"] as? [[String: Any]])
        expectEqual(input.first?["text"] as? String, "first prompt")
    }

    @Test
    func testCodexInputQueueRejectsOversizedPromptBeforeThread() async throws {
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { _ in },
            outputSink: { _, _ in }
        )

        try await session.start()
        await expectThrowsErrorAsync {
            try await session.submit(String(repeating: "x", count: 64 * 1024 + 1))
        }
    }

    @Test
    func testAutoReviewPermissionModeAddsCodexReviewerOverride() async throws {
        var sentLines: [String] = []
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { data in
                sentLines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            },
            outputSink: { _, _ in }
        )

        try await session.start()
        session.consumeStdout(
            #"{"id":1,"result":{"userAgent":"codex","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}"#
                + "\n")
        await Task.yield()
        session.consumeStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"# + "\n")
        try await session.submit("please review", permissionMode: .autoReview)

        let turnStart = jsonLine(sentLines[3])
        expectEqual(turnStart["method"] as? String, "turn/start")
        let turnParams = try #require(turnStart["params"] as? [String: Any])
        expectEqual(turnParams["threadId"] as? String, "thread-1")
        expectEqual(turnParams["approvalPolicy"] as? String, "on-request")
        expectEqual(turnParams["approvalsReviewer"] as? String, "auto_review")
        expectTrue(turnParams["sandboxPolicy"] is NSNull)
    }

    @Test
    func testCustomPermissionModeLeavesCodexConfigInControl() async throws {
        var sentLines: [String] = []
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { data in
                sentLines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            },
            outputSink: { _, _ in }
        )

        try await session.start()
        session.consumeStdout(
            #"{"id":1,"result":{"userAgent":"codex","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}"#
                + "\n")
        await Task.yield()
        session.consumeStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"# + "\n")
        try await session.submit("use config", permissionMode: .custom)

        let turnStart = jsonLine(sentLines[3])
        expectEqual(turnStart["method"] as? String, "turn/start")
        let turnParams = try #require(turnStart["params"] as? [String: Any])
        expectEqual(turnParams["threadId"] as? String, "thread-1")
        expectNil(turnParams["approvalPolicy"])
        expectNil(turnParams["approvalsReviewer"])
        expectNil(turnParams["sandboxPolicy"])
    }

    @Test
    func testDefaultPermissionModeAvoidsInteractiveCodexApprovals() async throws {
        var sentLines: [String] = []
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { data in
                sentLines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            },
            outputSink: { _, _ in }
        )

        try await session.start()
        session.consumeStdout(
            #"{"id":1,"result":{"userAgent":"codex","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}"#
                + "\n")
        await Task.yield()
        session.consumeStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"# + "\n")
        try await session.submit("use full access", permissionMode: .fullAccess)
        session.consumeStdout(#"{"method":"turn/completed","params":{"threadId":"thread-1"}}"# + "\n")
        try await session.submit("back to defaults", permissionMode: .standard)

        let elevatedParams = try #require(jsonLine(sentLines[3])["params"] as? [String: Any])
        expectEqual(elevatedParams["approvalPolicy"] as? String, "never")
        let elevatedSandboxPolicy = try #require(elevatedParams["sandboxPolicy"] as? [String: Any])
        expectEqual(elevatedSandboxPolicy["type"] as? String, "dangerFullAccess")

        let defaultParams = try #require(jsonLine(sentLines[4])["params"] as? [String: Any])
        expectEqual(defaultParams["approvalPolicy"] as? String, "never")
        expectTrue(defaultParams["approvalsReviewer"] is NSNull)
        expectTrue(defaultParams["sandboxPolicy"] is NSNull)
    }

    @Test
    func testCodexSubmitBlocksReentrantTurnWhileWriteIsPending() async throws {
        var sentLines: [String] = []
        var pendingTurnWrite: CheckedContinuation<Void, Never>?
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { data in
                let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
                if line.contains(#""method":"turn/start""#) {
                    await withCheckedContinuation { continuation in
                        pendingTurnWrite = continuation
                    }
                }
                sentLines.append(line)
            },
            outputSink: { _, _ in }
        )

        try await session.start()
        session.consumeStdout(
            #"{"id":1,"result":{"userAgent":"codex","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}"#
                + "\n")
        await Task.yield()
        session.consumeStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"# + "\n")

        let firstSubmit = Task { try await session.submit("first prompt") }
        while pendingTurnWrite == nil {
            await Task.yield()
        }

        await expectThrowsErrorAsync {
            try await session.submit("second prompt")
        }

        pendingTurnWrite?.resume()
        try await firstSubmit.value
        expectEqual(sentLines.count, 4)
        let turnParams = try #require(jsonLine(sentLines[3])["params"] as? [String: Any])
        let input = try #require(turnParams["input"] as? [[String: Any]])
        expectEqual(input.first?["text"] as? String, "first prompt")
    }

    @Test
    func testCodexApprovalRequestsOnlyAutoApproveForFullAccessMode() async throws {
        var sentLines: [String] = []
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { data in
                sentLines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            },
            outputSink: { _, _ in }
        )

        try await session.start()
        session.consumeStdout(
            #"{"id":1,"result":{"userAgent":"codex","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}"#
                + "\n")
        await Task.yield()
        session.consumeStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"# + "\n")
        try await session.submit("default prompt", permissionMode: .standard)
        session.consumeStdout(
            #"{"id":"cmd-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1"}}"# + "\n")
        session.consumeStdout(
            #"{"id":"perm-1","method":"item/permissions/requestApproval","params":{"permissions":{"network":{"enabled":true}}}}"# + "\n")
        await expectThrowsErrorAsync {
            try await session.submit("blocked full access prompt", permissionMode: .fullAccess)
        }
        session.consumeStdout(#"{"method":"turn/completed","params":{"threadId":"thread-1"}}"# + "\n")
        try await session.submit("full access prompt", permissionMode: .fullAccess)
        session.consumeStdout(
            #"{"id":"cmd-2","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1"}}"# + "\n")
        session.consumeStdout(
            #"{"id":"perm-2","method":"item/permissions/requestApproval","params":{"permissions":{"network":{"enabled":true}}}}"# + "\n")

        let defaultCommandResponse = jsonLine(sentLines[4])
        let defaultCommandResult = try #require(defaultCommandResponse["result"] as? [String: Any])
        expectEqual(defaultCommandResult["decision"] as? String, "decline")

        let defaultPermissionResponse = jsonLine(sentLines[5])
        let defaultPermissionResult = try #require(defaultPermissionResponse["result"] as? [String: Any])
        let defaultPermissions = try #require(defaultPermissionResult["permissions"] as? [String: Any])
        expectTrue(defaultPermissions.isEmpty)

        let fullAccessCommandResponse = jsonLine(sentLines[7])
        let fullAccessCommandResult = try #require(fullAccessCommandResponse["result"] as? [String: Any])
        expectEqual(fullAccessCommandResult["decision"] as? String, "acceptForSession")

        let fullAccessPermissionResponse = jsonLine(sentLines[8])
        let fullAccessPermissionResult = try #require(fullAccessPermissionResponse["result"] as? [String: Any])
        let fullAccessPermissions = try #require(fullAccessPermissionResult["permissions"] as? [String: Any])
        let networkPermissions = try #require(fullAccessPermissions["network"] as? [String: Any])
        expectEqual(networkPermissions["enabled"] as? Bool, true)
    }

    @Test
    func testAppServerUserInputRequestsUseTheFeedResolutionHandler() async throws {
        var sentLines: [String] = []
        var receivedRequest: CodexAppServerUserInputRequest?
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { data in
                sentLines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            },
            outputSink: { _, _ in },
            userInputHandler: { request in
                receivedRequest = request
                return .result(json: #"{"answers":{"mode":{"answers":["Fast"]}}}"#)
            }
        )

        session.consumeStdout(
            #"{"id":"input-1","method":"item/tool/requestUserInput","params":{"threadId":"thread-1","questions":[{"id":"mode","question":"Choose","options":[{"label":"Fast"}]}],"isBlocking":false,"autoResolutionMs":4500}}"#
                + "\n"
        )
        for _ in 0..<3 { await Task.yield() }

        let request = try #require(receivedRequest)
        expectEqual(request.rpcID, "input-1")
        expectEqual(request.method, "item/tool/requestUserInput")
        expectEqual(request.isBlocking, false)
        expectEqual(request.autoResolutionMilliseconds, 4500)
        let response = try #require(sentLines.first.flatMap(jsonLine(_:))["result"] as? [String: Any])
        let answers = try #require(response["answers"] as? [String: Any])
        let mode = try #require(answers["mode"] as? [String: Any])
        expectEqual(mode["answers"] as? [String], ["Fast"])
    }

    @Test
    func testMCPElicitationRequestsPreserveBidirectionalMethodAndResult() async throws {
        var sentLines: [String] = []
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { data in
                sentLines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            },
            outputSink: { _, _ in },
            userInputHandler: { request in
                expectEqual(request.method, "mcpServer/elicitation/request")
                return .result(json: #"{"action":"accept","content":{"branch":"main"}}"#)
            }
        )

        session.consumeStdout(
            #"{"id":9,"method":"mcpServer/elicitation/request","params":{"message":"Choose a branch","requestedSchema":{"type":"object","properties":{"branch":{"type":"string"}}}}}"#
                + "\n"
        )
        for _ in 0..<3 { await Task.yield() }

        let response = try #require(sentLines.first.flatMap(jsonLine(_:)))
        expectEqual(response["id"] as? Int, 9)
        expectEqual((response["result"] as? [String: Any])?["action"] as? String, "accept")
    }

    @Test
    func testResolvedServerRequestInvalidatesPendingFeedInputWithoutLateResponse() async throws {
        var sentLines: [String] = []
        var resolvedRequestIDs: [String] = []
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { data in
                sentLines.append(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            },
            outputSink: { _, _ in },
            userInputHandler: { _ in
                .result(json: #"{"answers":{}}"#)
            },
            userInputResolvedSink: { resolvedRequestIDs.append($0) }
        )

        session.consumeStdout(
            #"{"id":"input-stale","method":"item/tool/requestUserInput","params":{"questions":[],"isBlocking":true}}"#
                + "\n"
        )
        session.consumeStdout(
            #"{"method":"serverRequest/resolved","params":{"threadId":"thread-1","requestId":"input-stale"}}"#
                + "\n"
        )
        for _ in 0..<3 { await Task.yield() }

        expectEqual(resolvedRequestIDs, ["input-stale"])
        expectTrue(sentLines.isEmpty)
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
    func testMapsCodexV2FileChangeKindToSpecificActivityAction() {
        var activities: [[String: Any]] = []
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { _ in },
            outputSink: { _, _ in },
            activitySink: { activity in activities.append(activity) }
        )

        session.consumeStdout(
            #"{"method":"item/completed","params":{"item":{"id":"file-1","type":"fileChange","status":"completed","changes":[{"path":"Created.swift","kind":{"type":"add"}}]}}}"#
                + "\n")
        session.consumeStdout(
            #"{"method":"item/fileChange/patchUpdated","params":{"itemId":"file-2","changes":[{"path":"Deleted.swift","kind":{"type":"delete"}}]}}"#
                + "\n")

        expectEqual(activities.count, 2)
        expectEqual(activities[0]["detail"] as? String, "Created.swift")
        expectEqual(activities[0]["action"] as? String, "Created")
        expectEqual(activities[1]["detail"] as? String, "Deleted.swift")
        expectEqual(activities[1]["action"] as? String, "Deleting")
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
    func testInitializeErrorFailsStartupAndRejectsLaterPrompts() async throws {
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

        try await session.start()
        let submitTask = Task { try await session.submit("queued prompt") }
        session.consumeStdout(#"{"id":1,"error":{"message":"unsupported initialize"}}"# + "\n")
        await expectThrowsErrorAsync {
            try await submitTask.value
        }

        expectEqual(sentLines.count, 1)
        expectEqual(failures.count, 1)
        expectEqual(failures.first!, "unsupported initialize")
        expectEqual(output.last?.0, "stderr")
        expectEqual(output.last?.1, "Codex app-server request failed.")
        await expectThrowsErrorAsync {
            try await session.submit("later prompt")
        }
    }

    @Test
    func testThreadStartErrorClearsStartupStateAndRejectsLaterPrompts() async throws {
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

        try await session.start()
        session.consumeStdout(#"{"id":1,"result":{}}"# + "\n")
        await Task.yield()
        expectEqual(jsonLine(sentLines[2])["method"] as? String, "thread/start")

        let submitTask = Task { try await session.submit("queued prompt") }
        session.consumeStdout(#"{"id":2,"error":{"message":"bad cwd"}}"# + "\n")
        await expectThrowsErrorAsync {
            try await submitTask.value
        }

        expectEqual(failures.count, 1)
        expectEqual(failures.first!, "bad cwd")
        expectEqual(sentLines.count, 3)
        await expectThrowsErrorAsync {
            try await session.submit("later prompt")
        }
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
