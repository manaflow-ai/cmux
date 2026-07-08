import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct CmuxAgentChatConfigTests {

    private func decode(_ json: String) throws -> CmuxConfigFile {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(CmuxConfigFile.self, from: data)
    }

    @Test func decodeAgentChatConfigTrimsURLAndStartCommand() throws {
        let json = """
        {
          "agentChat": {
            "url": "  http://127.0.0.1:8777/chat  ",
            "startCommand": "  cmux-chat --port 8777  "
          }
        }
        """
        let config = try decode(json)
        #expect(config.agentChat?.url == "http://127.0.0.1:8777/chat")
        #expect(config.agentChat?.startCommand == "cmux-chat --port 8777")
        let resolved = CmuxAgentChatConfiguration.resolved(local: config.agentChat, global: nil)
        #expect(resolved.healthURL.absoluteString == "http://127.0.0.1:8777/chat/healthz")
    }

    @Test func decodeAgentChatRejectsBlankAndNonHTTPURL() {
        #expect(throws: (any Error).self) {
            try decode("""
        {
          "agentChat": {
            "url": "   "
          }
        }
        """)
        }
        #expect(throws: (any Error).self) {
            try decode("""
        {
          "agentChat": {
            "url": "file:///tmp/chat"
          }
        }
        """)
        }
        #expect(throws: (any Error).self) {
            try decode("""
        {
          "agentChat": {
            "startCommand": "   "
          }
        }
        """)
        }
    }

    @Test func resolveLocalURLOnlyDoesNotInheritGlobalStartCommand() {
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

        #expect(resolved.url.absoluteString == "http://127.0.0.1:9010")
        #expect(resolved.startCommand == nil)
        #expect(resolved.source == .local(path: localPath))
        #expect(resolved.source.sourcePath == localPath)
        #expect(!resolved.startCommandRequiresTrust)
    }

    @Test func resolveLocalSidecarOnlyFieldsUseGlobalServerConfig() throws {
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

        #expect(resolved.url.absoluteString == "http://127.0.0.1:9000")
        #expect(resolved.startCommand == "cmux-chat --port 9000")
        #expect(resolved.source == .global(path: globalPath))
        #expect(!resolved.startCommandRequiresTrust)
    }

    @Test func resolveLocalStartCommandOnlyUsesDefaultURL() {
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

        #expect(resolved.url.absoluteString == CmuxAgentChatConfiguration.defaultURLString)
        #expect(resolved.startCommand == "cmux-chat --port 9010")
        #expect(resolved.source == .local(path: localPath))
        #expect(resolved.startCommandRequiresTrust)
    }

    @Test func resolveNoLocalUsesGlobalBlock() {
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

        #expect(resolved.url.absoluteString == "http://127.0.0.1:9000")
        #expect(resolved.startCommand == "cmux-chat --port 9000")
        #expect(resolved.source == .global(path: globalPath))
        #expect(!resolved.startCommandRequiresTrust)
    }

    @Test func resolveNeitherUsesDefaultBlock() {
        let resolved = CmuxAgentChatConfiguration.resolved(local: nil, global: nil)

        #expect(resolved.url.absoluteString == CmuxAgentChatConfiguration.defaultURLString)
        #expect(resolved.startCommand == nil)
        #expect(resolved.source == .defaults)
        #expect(resolved.source.sourcePath == nil)
        #expect(!resolved.startCommandRequiresTrust)
    }
}
