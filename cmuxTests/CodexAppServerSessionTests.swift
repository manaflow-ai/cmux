import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CodexAppServerSessionTests: XCTestCase {
    func testOpenCodeAuthHeaderMatchesServerEnvironment() {
        XCTAssertNil(OpenCodeServerAuth(environment: [:]))
        XCTAssertNil(OpenCodeServerAuth(environment: ["OPENCODE_SERVER_PASSWORD": ""]))

        XCTAssertEqual(
            OpenCodeServerAuth(environment: ["OPENCODE_SERVER_PASSWORD": "secret"])?.authorizationHeader,
            "Basic b3BlbmNvZGU6c2VjcmV0"
        )
        XCTAssertEqual(
            OpenCodeServerAuth(environment: [
                "OPENCODE_SERVER_USERNAME": "cmux",
                "OPENCODE_SERVER_PASSWORD": "secret",
            ])?.authorizationHeader,
            "Basic Y211eDpzZWNyZXQ="
        )
    }

    func testOpenCodeEventStreamParserDecodesDataEvents() {
        var parser = OpenCodeEventStreamParser()

        XCTAssertEqual(parser.consumeLine("event: message").count, 0)
        XCTAssertEqual(parser.consumeLine(#"data: {"type":"server.connected","properties":{}}"#).count, 0)
        let events = parser.consumeLine("")

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["type"] as? String, "server.connected")
    }

    func testOpenCodeEventTextAccumulatorEmitsAssistantTextDeltasAfterRoleAndPartAreKnown() {
        var accumulator = OpenCodeEventTextAccumulator()

        XCTAssertEqual(
            accumulator.consumeEvent([
                "type": "message.part.delta",
                "properties": [
                    "sessionID": "session-1",
                    "messageID": "message-1",
                    "partID": "part-1",
                    "field": "text",
                    "delta": "hel"
                ]
            ], sessionID: "session-1"),
            []
        )
        XCTAssertEqual(
            accumulator.consumeEvent([
                "type": "message.part.updated",
                "properties": [
                    "sessionID": "session-1",
                    "part": [
                        "id": "part-1",
                        "sessionID": "session-1",
                        "messageID": "message-1",
                        "type": "text",
                        "text": "hel"
                    ]
                ]
            ], sessionID: "session-1"),
            []
        )
        XCTAssertEqual(
            accumulator.consumeEvent([
                "type": "message.updated",
                "properties": [
                    "sessionID": "session-1",
                    "info": [
                        "id": "message-1",
                        "role": "assistant"
                    ]
                ]
            ], sessionID: "session-1"),
            ["hel"]
        )
        XCTAssertEqual(
            accumulator.consumeEvent([
                "type": "message.part.delta",
                "properties": [
                    "sessionID": "session-1",
                    "messageID": "message-1",
                    "partID": "part-1",
                    "field": "text",
                    "delta": "lo"
                ]
            ], sessionID: "session-1"),
            ["lo"]
        )
    }

    func testOpenCodeEventTextAccumulatorSkipsUserAndIgnoredText() {
        var accumulator = OpenCodeEventTextAccumulator()

        XCTAssertEqual(
            accumulator.consumeEvent([
                "type": "message.updated",
                "properties": [
                    "sessionID": "session-1",
                    "info": [
                        "id": "message-1",
                        "role": "user"
                    ]
                ]
            ], sessionID: "session-1"),
            []
        )
        XCTAssertEqual(
            accumulator.consumeEvent([
                "type": "message.part.updated",
                "properties": [
                    "sessionID": "session-1",
                    "part": [
                        "id": "part-1",
                        "sessionID": "session-1",
                        "messageID": "message-1",
                        "type": "text",
                        "text": "do not echo"
                    ]
                ]
            ], sessionID: "session-1"),
            []
        )
        XCTAssertEqual(
            accumulator.consumeEvent([
                "type": "message.updated",
                "properties": [
                    "sessionID": "session-1",
                    "info": [
                        "id": "message-2",
                        "role": "assistant"
                    ]
                ]
            ], sessionID: "session-1"),
            []
        )
        XCTAssertEqual(
            accumulator.consumeEvent([
                "type": "message.part.updated",
                "properties": [
                    "sessionID": "session-1",
                    "part": [
                        "id": "part-2",
                        "sessionID": "session-1",
                        "messageID": "message-2",
                        "type": "text",
                        "text": "hidden",
                        "ignored": true
                    ]
                ]
            ], sessionID: "session-1"),
            []
        )
    }

    func testOpenCodeEventTextAccumulatorAcceptsNestedSessionIDs() {
        var accumulator = OpenCodeEventTextAccumulator()

        XCTAssertEqual(
            accumulator.consumeEvent([
                "type": "message.part.updated",
                "properties": [
                    "part": [
                        "id": "part-1",
                        "sessionID": "session-1",
                        "messageID": "message-1",
                        "type": "text",
                        "text": "nested"
                    ]
                ]
            ], sessionID: "session-1"),
            []
        )
        XCTAssertEqual(
            accumulator.consumeEvent([
                "type": "message.updated",
                "properties": [
                    "info": [
                        "id": "message-1",
                        "sessionID": "session-1",
                        "role": "assistant"
                    ]
                ]
            ], sessionID: "session-1"),
            ["nested"]
        )
        XCTAssertEqual(
            accumulator.consumeEvent([
                "type": "message.part.delta",
                "properties": [
                    "sessionID": "session-2",
                    "messageID": "message-1",
                    "partID": "part-1",
                    "field": "text",
                    "delta": "ignored"
                ]
            ], sessionID: "session-1"),
            []
        )
    }

    func testClaudeStreamJSONAccumulatorExtractsAssistantTextDeltas() {
        var accumulator = ClaudeStreamJSONAccumulator()

        XCTAssertEqual(
            accumulator.consumeLine(#"{"type":"system","subtype":"init"}"#),
            []
        )
        XCTAssertEqual(
            accumulator.consumeLine(#"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"hello"}]}}"#),
            ["hello"]
        )
        XCTAssertEqual(
            accumulator.consumeLine(#"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"hello world"}]}}"#),
            [" world"]
        )
        XCTAssertEqual(
            accumulator.consumeLine(#"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"hello world"}]}}"#),
            []
        )
    }

    func testClaudeStreamJSONAccumulatorFallsBackToResultWhenNoAssistantTextArrived() {
        var accumulator = ClaudeStreamJSONAccumulator()

        XCTAssertEqual(
            accumulator.consumeLine(#"{"type":"result","subtype":"success","result":"done"}"#),
            ["done"]
        )
        XCTAssertEqual(
            accumulator.consumeLine(#"{"type":"result","subtype":"success","result":"done again"}"#),
            []
        )
    }

    func testClaudeStreamJSONAccumulatorDoesNotDuplicateFinalAssistantMessageAfterDeltas() {
        var accumulator = ClaudeStreamJSONAccumulator()

        XCTAssertEqual(
            accumulator.consumeLine(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"hel"}}"#),
            ["hel"]
        )
        XCTAssertEqual(
            accumulator.consumeLine(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"lo"}}"#),
            ["lo"]
        )
        XCTAssertEqual(
            accumulator.consumeLine(#"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"hello world"}]}}"#),
            [" world"]
        )
    }

    func testClaudeStreamJSONAccumulatorTracksDeltaTextPerAssistantMessage() {
        var accumulator = ClaudeStreamJSONAccumulator()

        XCTAssertEqual(
            accumulator.consumeLine(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"first"}}"#),
            ["first"]
        )
        XCTAssertEqual(
            accumulator.consumeLine(#"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"first done"}]}}"#),
            [" done"]
        )
        XCTAssertEqual(
            accumulator.consumeLine(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"second"}}"#),
            ["second"]
        )
        XCTAssertEqual(
            accumulator.consumeLine(#"{"type":"assistant","message":{"id":"msg_2","role":"assistant","content":[{"type":"text","text":"second done"}]}}"#),
            [" done"]
        )
    }

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
        XCTAssertEqual(jsonLine(sentLines[0])["method"] as? String, "initialize")

        session.consumeStdout(#"{"id":1,"result":{"userAgent":"codex","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}"# + "\n")
        XCTAssertEqual(jsonLine(sentLines[1])["method"] as? String, "initialized")

        let threadStart = jsonLine(sentLines[2])
        XCTAssertEqual(threadStart["method"] as? String, "thread/start")
        let threadParams = try XCTUnwrap(threadStart["params"] as? [String: Any])
        XCTAssertEqual(threadParams["cwd"] as? String, "/tmp/cmux-agent-session-test")

        try session.submit("hello codex")
        XCTAssertEqual(sentLines.count, 3, "Prompt should queue until thread/start returns a thread id.")

        session.consumeStdout(#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"# + "\n")
        let turnStart = jsonLine(sentLines[3])
        XCTAssertEqual(turnStart["method"] as? String, "turn/start")
        let turnParams = try XCTUnwrap(turnStart["params"] as? [String: Any])
        XCTAssertEqual(turnParams["threadId"] as? String, "thread-1")
        let input = try XCTUnwrap(turnParams["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["type"] as? String, "text")
        XCTAssertEqual(input.first?["text"] as? String, "hello codex")

        for line in sentLines {
            XCTAssertTrue(line.hasPrefix("{"), "Codex app-server stdin must stay JSON-RPC, got \(line)")
        }
    }

    func testMapsAgentMessageDeltaToStdout() {
        var output: [(String, String)] = []
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { _ in },
            outputSink: { stream, text in output.append((stream, text)) }
        )

        session.consumeStdout(#"{"method":"item/agentMessage/delta","params":{"delta":"partial answer"}}"# + "\n")

        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output.first?.0, "stdout")
        XCTAssertEqual(output.first?.1, "partial answer")
    }

    func testDeclinedToolItemsDoNotRenderAsCompletedActivity() {
        var activities: [[String: Any]] = []
        let session = CodexAppServerSession(
            workingDirectory: nil,
            writeData: { _ in },
            outputSink: { _, _ in },
            activitySink: { activity in activities.append(activity) }
        )

        session.consumeStdout(#"{"method":"item/completed","params":{"item":{"id":"cmd-1","type":"commandExecution","status":"declined","command":"dangerous command"}}}"# + "\n")
        session.consumeStdout(#"{"method":"item/completed","params":{"item":{"id":"file-1","type":"fileChange","status":"declined","changes":[{"path":"README.md","type":"update","diff":""}]}}}"# + "\n")

        XCTAssertEqual(activities.count, 2)
        XCTAssertEqual(activities[0]["kind"] as? String, "command")
        XCTAssertEqual(activities[0]["status"] as? String, "stopped")
        XCTAssertEqual(activities[0]["action"] as? String, "Stopped")
        XCTAssertEqual(activities[1]["kind"] as? String, "fileChange")
        XCTAssertEqual(activities[1]["status"] as? String, "stopped")
        XCTAssertEqual(activities[1]["action"] as? String, "Stopped")
    }

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

        XCTAssertEqual(sentLines.count, 1)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first!, "unsupported initialize")
        XCTAssertEqual(output.last?.0, "stderr")
        XCTAssertEqual(output.last?.1, "Codex app-server request failed.")
        XCTAssertThrowsError(try session.submit("later prompt"))
    }

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
        XCTAssertEqual(jsonLine(sentLines[2])["method"] as? String, "thread/start")

        try session.submit("queued prompt")
        session.consumeStdout(#"{"id":2,"error":{"message":"bad cwd"}}"# + "\n")

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first!, "bad cwd")
        XCTAssertEqual(sentLines.count, 3)
        XCTAssertThrowsError(try session.submit("later prompt"))
    }

    private func jsonLine(_ rawLine: String, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        guard let data = rawLine.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data),
              let object = decoded as? [String: Any] else {
            XCTFail("Expected JSON object", file: file, line: line)
            return [:]
        }
        return object
    }
}
