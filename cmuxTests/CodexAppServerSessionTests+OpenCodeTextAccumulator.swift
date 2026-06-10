import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif


// MARK: - OpenCode event text accumulator
extension CodexAppServerSessionTests {
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

}
