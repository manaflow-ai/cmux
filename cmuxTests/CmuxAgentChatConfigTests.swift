import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CmuxAgentChatConfigTests: XCTestCase {

    private func decode(_ json: String) throws -> CmuxConfigFile {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(CmuxConfigFile.self, from: data)
    }

    func testDecodeAgentChatConfigTrimsURLAndStartCommand() throws {
        let json = """
        {
          "agentChat": {
            "url": "  http://127.0.0.1:8777/chat  ",
            "startCommand": "  cmux-chat --port 8777  "
          }
        }
        """
        let config = try decode(json)
        XCTAssertEqual(config.agentChat?.url, "http://127.0.0.1:8777/chat")
        XCTAssertEqual(config.agentChat?.startCommand, "cmux-chat --port 8777")
        let resolved = CmuxAgentChatConfiguration.resolved(local: config.agentChat, global: nil)
        XCTAssertEqual(resolved.healthURL.absoluteString, "http://127.0.0.1:8777/chat/healthz")
    }

    func testDecodeAgentChatRejectsBlankAndNonHTTPURL() {
        XCTAssertThrowsError(try decode("""
        {
          "agentChat": {
            "url": "   "
          }
        }
        """))
        XCTAssertThrowsError(try decode("""
        {
          "agentChat": {
            "url": "file:///tmp/chat"
          }
        }
        """))
        XCTAssertThrowsError(try decode("""
        {
          "agentChat": {
            "startCommand": "   "
          }
        }
        """))
    }

    func testResolveLocalURLOnlyDoesNotInheritGlobalStartCommand() {
        let resolved = CmuxAgentChatConfiguration.resolved(
            local: CmuxAgentChatConfigDefinition(url: "http://127.0.0.1:9010"),
            global: CmuxAgentChatConfigDefinition(
                url: "http://127.0.0.1:9000",
                startCommand: "cmux-chat --port 9000"
            )
        )

        XCTAssertEqual(resolved.url.absoluteString, "http://127.0.0.1:9010")
        XCTAssertNil(resolved.startCommand)
    }

    func testResolveLocalStartCommandOnlyUsesDefaultURL() {
        let resolved = CmuxAgentChatConfiguration.resolved(
            local: CmuxAgentChatConfigDefinition(startCommand: "cmux-chat --port 9010"),
            global: CmuxAgentChatConfigDefinition(
                url: "http://127.0.0.1:9000",
                startCommand: "cmux-chat --port 9000"
            )
        )

        XCTAssertEqual(resolved.url.absoluteString, CmuxAgentChatConfiguration.defaultURLString)
        XCTAssertEqual(resolved.startCommand, "cmux-chat --port 9010")
    }

    func testResolveNoLocalUsesGlobalBlock() {
        let resolved = CmuxAgentChatConfiguration.resolved(
            local: nil,
            global: CmuxAgentChatConfigDefinition(
                url: "http://127.0.0.1:9000",
                startCommand: "cmux-chat --port 9000"
            )
        )

        XCTAssertEqual(resolved.url.absoluteString, "http://127.0.0.1:9000")
        XCTAssertEqual(resolved.startCommand, "cmux-chat --port 9000")
    }

    func testResolveNeitherUsesDefaultBlock() {
        let resolved = CmuxAgentChatConfiguration.resolved(local: nil, global: nil)

        XCTAssertEqual(resolved.url.absoluteString, CmuxAgentChatConfiguration.defaultURLString)
        XCTAssertNil(resolved.startCommand)
    }
}
