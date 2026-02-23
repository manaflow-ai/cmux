import XCTest
@testable import cmux_DEV

final class ToolCallFormattingTests: XCTestCase {
    func testPrettifyJsonSortsKeys() {
        let input = "{\"b\":1,\"a\":2}"
        let expected = "{\n  \"a\" : 2,\n  \"b\" : 1\n}"
        XCTAssertEqual(ToolCallPayloadFormatter.prettify(input), expected)
    }

    func testPrettifyInvalidJsonReturnsOriginal() {
        let input = "not json"
        XCTAssertEqual(ToolCallPayloadFormatter.prettify(input), input)
    }

    func testToolCallMappingPreservesFields() {
        let toolCall = ConversationMessagesListByConversationReturnMessagesItemToolCallsItem(
            result: "{\"ok\":true}",
            id: "tool_123",
            name: "Fetch https://example.com",
            status: .running,
            arguments: "{\"url\":\"https://example.com\"}",
            acpSeq: 12
        )
        let mapped = MessageToolCall(toolCall)

        XCTAssertEqual(mapped.id, "tool_123")
        XCTAssertEqual(mapped.name, "Fetch https://example.com")
        XCTAssertEqual(mapped.status, .running)
        XCTAssertEqual(mapped.arguments, "{\"url\":\"https://example.com\"}")
        XCTAssertEqual(mapped.result, "{\"ok\":true}")
        XCTAssertEqual(mapped.acpSeq, 12)
    }
}
