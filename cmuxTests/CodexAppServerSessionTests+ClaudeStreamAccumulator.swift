import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif


// MARK: - Claude stream JSON accumulator
extension CodexAppServerSessionTests {
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

}
