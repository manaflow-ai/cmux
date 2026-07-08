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
        let localPath = "/repo/cmux.json"
        let globalPath = "/Users/me/.config/cmux/cmux.json"
        let resolved = CmuxAgentChatConfiguration.resolved(
            local: CmuxAgentChatConfigDefinition(url: "http://127.0.0.1:9010"),
            global: CmuxAgentChatConfigDefinition(
                url: "http://127.0.0.1:9000",
                startCommand: "cmux-chat --port 9000"
            ),
            localSourcePath: localPath,
            globalSourcePath: globalPath
        )

        XCTAssertEqual(resolved.url.absoluteString, "http://127.0.0.1:9010")
        XCTAssertNil(resolved.startCommand)
        XCTAssertEqual(resolved.source, .local(path: localPath))
        XCTAssertEqual(resolved.source.sourcePath, localPath)
        XCTAssertFalse(resolved.startCommandRequiresTrust)
    }

    func testResolveLocalSidecarOnlyFieldsUseGlobalServerConfig() throws {
        let localPath = "/repo/cmux.json"
        let globalPath = "/Users/me/.config/cmux/cmux.json"
        let localConfig = try decode("""
        {
          "agentChat": {
            "fontSize": 14,
            "keymap": "vim"
          }
        }
        """)
        let resolved = CmuxAgentChatConfiguration.resolved(
            local: localConfig.agentChat,
            global: CmuxAgentChatConfigDefinition(
                url: "http://127.0.0.1:9000",
                startCommand: "cmux-chat --port 9000"
            ),
            localSourcePath: localPath,
            globalSourcePath: globalPath
        )

        XCTAssertEqual(resolved.url.absoluteString, "http://127.0.0.1:9000")
        XCTAssertEqual(resolved.startCommand, "cmux-chat --port 9000")
        XCTAssertEqual(resolved.source, .global(path: globalPath))
        XCTAssertFalse(resolved.startCommandRequiresTrust)
    }

    func testResolveLocalStartCommandOnlyUsesDefaultURL() {
        let localPath = "/repo/cmux.json"
        let resolved = CmuxAgentChatConfiguration.resolved(
            local: CmuxAgentChatConfigDefinition(startCommand: "cmux-chat --port 9010"),
            global: CmuxAgentChatConfigDefinition(
                url: "http://127.0.0.1:9000",
                startCommand: "cmux-chat --port 9000"
            ),
            localSourcePath: localPath,
            globalSourcePath: "/Users/me/.config/cmux/cmux.json"
        )

        XCTAssertEqual(resolved.url.absoluteString, CmuxAgentChatConfiguration.defaultURLString)
        XCTAssertEqual(resolved.startCommand, "cmux-chat --port 9010")
        XCTAssertEqual(resolved.source, .local(path: localPath))
        XCTAssertTrue(resolved.startCommandRequiresTrust)
    }

    func testResolveNoLocalUsesGlobalBlock() {
        let globalPath = "/Users/me/.config/cmux/cmux.json"
        let resolved = CmuxAgentChatConfiguration.resolved(
            local: nil,
            global: CmuxAgentChatConfigDefinition(
                url: "http://127.0.0.1:9000",
                startCommand: "cmux-chat --port 9000"
            ),
            localSourcePath: nil,
            globalSourcePath: globalPath
        )

        XCTAssertEqual(resolved.url.absoluteString, "http://127.0.0.1:9000")
        XCTAssertEqual(resolved.startCommand, "cmux-chat --port 9000")
        XCTAssertEqual(resolved.source, .global(path: globalPath))
        XCTAssertFalse(resolved.startCommandRequiresTrust)
    }

    func testResolveNeitherUsesDefaultBlock() {
        let resolved = CmuxAgentChatConfiguration.resolved(local: nil, global: nil)

        XCTAssertEqual(resolved.url.absoluteString, CmuxAgentChatConfiguration.defaultURLString)
        XCTAssertNil(resolved.startCommand)
        XCTAssertEqual(resolved.source, .defaults)
        XCTAssertNil(resolved.source.sourcePath)
        XCTAssertFalse(resolved.startCommandRequiresTrust)
    }
}
