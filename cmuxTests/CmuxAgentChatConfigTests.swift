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

    @MainActor
    func testStoreResolvesAgentChatDefaultsAndLocalOverridesGlobal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-agent-chat-config-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missingGlobal = root.appendingPathComponent("missing-global.json")
        let defaultsStore = CmuxConfigStore(
            globalConfigPath: missingGlobal.path,
            localConfigPath: nil,
            startFileWatchers: false
        )
        defaultsStore.loadAll()
        XCTAssertEqual(defaultsStore.agentChat.url.absoluteString, CmuxAgentChatConfiguration.defaultURLString)
        XCTAssertNil(defaultsStore.agentChat.startCommand)

        let globalConfigURL = root.appendingPathComponent("global-cmux.json")
        try """
        {
          "agentChat": {
            "url": "http://127.0.0.1:9000",
            "startCommand": "cmux-chat --port 9000"
          }
        }
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        let localConfigURL = root.appendingPathComponent("cmux.json")
        try """
        {
          "agentChat": {
            "url": "http://127.0.0.1:9010"
          }
        }
        """.write(to: localConfigURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: globalConfigURL.path,
            localConfigPath: localConfigURL.path,
            startFileWatchers: false
        )
        store.loadAll()
        XCTAssertEqual(store.agentChat.url.absoluteString, "http://127.0.0.1:9010")
        XCTAssertEqual(store.agentChat.startCommand, "cmux-chat --port 9000")
    }
}
