import XCTest
@testable import cmux_DEV

final class AssistantMessageItemBuilderTests: XCTestCase {
    func testBuildOrdersByAcpSeq() {
        let content = [
            MessageContentPart(text: "First", acpSeq: 10),
            MessageContentPart(text: "Second", acpSeq: 30),
        ]
        let toolCalls = [
            MessageToolCall(
                id: "tool-1",
                name: "Tool One",
                status: .running,
                arguments: "{}",
                result: nil,
                acpSeq: 20
            )
        ]

        let items = AssistantMessageItemBuilder.build(
            messageId: "msg-1",
            content: content,
            toolCalls: toolCalls
        )

        let labels = items.map { item in
            switch item.kind {
            case .text(let text):
                return "text:\(text)"
            case .toolCall(let toolCall):
                return "tool:\(toolCall.id)"
            }
        }

        XCTAssertEqual(labels, ["text:First", "tool:tool-1", "text:Second"])
    }

    func testBuildFallsBackToInsertionOrderWhenNoSeq() {
        let content = [
            MessageContentPart(text: "Alpha", acpSeq: nil),
            MessageContentPart(text: "Beta", acpSeq: nil),
        ]
        let toolCalls = [
            MessageToolCall(
                id: "tool-1",
                name: "Tool One",
                status: .pending,
                arguments: "{}",
                result: nil,
                acpSeq: nil
            )
        ]

        let items = AssistantMessageItemBuilder.build(
            messageId: "msg-2",
            content: content,
            toolCalls: toolCalls
        )

        let labels = items.map { item in
            switch item.kind {
            case .text(let text):
                return "text:\(text)"
            case .toolCall(let toolCall):
                return "tool:\(toolCall.id)"
            }
        }

        XCTAssertEqual(labels, ["text:Alpha\nBeta", "tool:tool-1"])
    }
}
