import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class VoiceToolDefinitionsTests: XCTestCase {
    func testAllToolsHaveNames() {
        let tools = VoiceToolDefinitions.all
        XCTAssertFalse(tools.isEmpty)
        for tool in tools {
            XCTAssertFalse(tool.name.isEmpty, "Tool at index has empty name")
        }
    }

    func testToolNamesMatchExpected() {
        let names = Set(VoiceToolDefinitions.all.map(\.name))
        XCTAssertTrue(names.contains("get_app_state"))
        XCTAssertTrue(names.contains("switch_workspace"))
        XCTAssertTrue(names.contains("switch_tab"))
        XCTAssertTrue(names.contains("type_text"))
        XCTAssertTrue(names.contains("execute_command"))
    }

    func testSwitchWorkspaceSchemaHasIdParameter() {
        let tool = VoiceToolDefinitions.all.first(where: { $0.name == "switch_workspace" })!
        XCTAssertEqual(tool.parameters.properties?["id"]?.type, "string")
        XCTAssertTrue(tool.parameters.required?.contains("id") ?? false)
    }

    func testParseToolCallDecoding() throws {
        let json = """
        {"call_id":"call_abc","name":"type_text","arguments":"{\\"text\\":\\"hello\\"}"}
        """
        let call = try JSONDecoder().decode(VoiceToolCall.self, from: Data(json.utf8))
        XCTAssertEqual(call.callId, "call_abc")
        XCTAssertEqual(call.name, "type_text")
    }
}
