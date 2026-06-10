import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif


// MARK: - Session event mapping to output/activity and turn completion
extension CodexAppServerSessionTests {
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

}
