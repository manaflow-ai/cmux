import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct CmuxAgentChatConfigTests {

    @MainActor
    private func withBrowserDisabled(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey) as? Bool
        let hadPrevious = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey) != nil
        BrowserAvailabilitySettings.setDisabled(true)
        defer {
            if hadPrevious, let previous {
                BrowserAvailabilitySettings.setDisabled(previous)
            } else {
                defaults.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
                NotificationCenter.default.post(name: BrowserAvailabilitySettings.didChangeNotification, object: nil)
            }
        }
        try body()
    }

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
        #expect(resolved.healthURL.absoluteString == "http://127.0.0.1:8777/healthz")
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

    @Test func newAgentChatInFlightGateRejectsDuplicatesUntilCleared() {
        let firstBegin = AgentChatActionInFlightGate.begin()
        #expect(firstBegin)
        guard firstBegin else { return }

        #expect(!AgentChatActionInFlightGate.begin())
        AgentChatActionInFlightGate.end()

        let secondBegin = AgentChatActionInFlightGate.begin()
        #expect(secondBegin)
        if secondBegin {
            AgentChatActionInFlightGate.end()
        }
    }

    @Test func agentChatThemePayloadUsesResolvedGhosttyConfigFields() throws {
        var config = GhosttyConfig()
        config.backgroundColor = try #require(NSColor(hex: "#102030"))
        config.foregroundColor = try #require(NSColor(hex: "#D0E0F0"))
        config.cursorColor = try #require(NSColor(hex: "#AA5500"))
        config.selectionBackground = try #require(NSColor(hex: "#334455"))
        config.fontFamily = " JetBrains Mono "
        config.fontSize = 13.5
        config.backgroundOpacity = 0.72
        config.backgroundBlur = .radius(18)
        let palette = [
            "#000001", "#000002", "#000003", "#000004",
            "#000005", "#000006", "#000007", "#000008",
            "#000009", "#00000A", "#00000B", "#00000C",
            "#00000D", "#00000E", "#00000F", "#000010",
        ]
        config.palette = Dictionary(uniqueKeysWithValues: try palette.enumerated().map { index, hex in
            (index, try #require(NSColor(hex: hex)))
        })

        let payload = AgentChatThemePayload(config: config)

        #expect(payload.background == "#102030")
        #expect(payload.foreground == "#D0E0F0")
        #expect(payload.palette == palette)
        #expect(payload.selectionBackground == "#334455")
        #expect(payload.cursorColor == "#AA5500")
        #expect(payload.fontFamily == "JetBrains Mono")
        #expect(payload.fontSize == 13.5)
        #expect(payload.opacity == 0.72)
        #expect(payload.blur == 18)
        #expect(payload.isLight == false)
        #expect(payload.source == "cmux")
    }

    @Test func agentChatThemeEndpointAppendsAPIThemeToConfiguredURL() throws {
        let url = try #require(URL(string: "http://127.0.0.1:7739/chat?ignored=1"))
        #expect(AgentChatThemeSync.themeURL(for: url).absoluteString == "http://127.0.0.1:7739/chat/api/theme")
    }

    @MainActor
    @Test func performNewAgentChatActionRejectsWhenBrowserSurfacesAreDisabled() throws {
        try withBrowserDisabled {
            let didStart = AppDelegate().performNewAgentChatAction(
                tabManager: TabManager(),
                agentChat: .default,
                globalConfigPath: nil,
                preferredWindow: nil
            )

            #expect(!didStart)
        }
    }
}
