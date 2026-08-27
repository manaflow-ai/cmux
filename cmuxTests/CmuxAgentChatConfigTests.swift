import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct CmuxAgentChatConfigTests {

    @MainActor
    private func withAgentChatUIFlag<T>(_ enabled: Bool, _ body: () throws -> T) throws -> T {
        let flags = CmuxFeatureFlags.shared
        let definition = try #require(CmuxFeatureFlags.allFlags.first { $0.key == "agent-chat-ui-enabled-release" })
        let previous = flags.overrideValue(for: definition)
        flags.setOverride(enabled, for: definition)
        defer { flags.setOverride(previous, for: definition) }
        return try body()
    }

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
        #expect(resolved.hasExplicitURL)
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
        #expect(resolved.hasExplicitURL)
        #expect(resolved.serverMode == .explicitURL)
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
        #expect(resolved.hasExplicitURL)
        #expect(resolved.serverMode == .explicitURL)
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
        #expect(!resolved.hasExplicitURL)
        #expect(resolved.serverMode == .appOwned)
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
        #expect(resolved.hasExplicitURL)
        #expect(resolved.serverMode == .explicitURL)
        #expect(!resolved.startCommandRequiresTrust)
    }

    @Test func resolveNeitherUsesDefaultBlock() {
        let resolved = CmuxAgentChatConfiguration.resolved(local: nil, global: nil)

        #expect(resolved.url.absoluteString == CmuxAgentChatConfiguration.defaultURLString)
        #expect(resolved.startCommand == nil)
        #expect(resolved.source == .defaults)
        #expect(resolved.source.sourcePath == nil)
        #expect(!resolved.hasExplicitURL)
        #expect(resolved.serverMode == .legacyDefaultURL)
        #expect(!resolved.startCommandRequiresTrust)
    }

    @Test func agentChatServerModeSelectsTheThreeURLStrategies() {
        let explicit = CmuxAgentChatConfiguration.resolved(
            local: CmuxAgentChatConfigDefinition(url: "http://127.0.0.1:9000/chat"),
            global: nil
        )
        let owned = CmuxAgentChatConfiguration.resolved(
            local: CmuxAgentChatConfigDefinition(startCommand: "cmux-chat"),
            global: nil
        )
        let legacy = CmuxAgentChatConfiguration.resolved(local: nil, global: nil)

        #expect(explicit.serverMode == .explicitURL)
        #expect(explicit.url.absoluteString == "http://127.0.0.1:9000/chat")
        #expect(owned.serverMode == .appOwned)
        #expect(owned.url.absoluteString == CmuxAgentChatConfiguration.defaultURLString)
        #expect(legacy.serverMode == .legacyDefaultURL)
        #expect(legacy.url.absoluteString == CmuxAgentChatConfiguration.defaultURLString)
    }

    @Test func agentChatStateFileParsesValidPortAndPID() throws {
        let data = try #require("""
        {"port":43123,"pid":9876,"launchId":"launch-1"}
        """.data(using: .utf8))

        let session = try #require(try AgentChatSidecarStateFile.parse(
            data,
            token: "token_123",
            launchId: "launch-1"
        ))

        #expect(session.port == 43123)
        #expect(session.pid == 9876)
        #expect(session.token == "token_123")
        #expect(session.healthURL.absoluteString == "http://127.0.0.1:43123/healthz")
    }

    @Test func agentChatStateFileRejectsInvalidPortOrPID() throws {
        let badPort = try #require("""
        {"port":0,"pid":9876,"launchId":"launch-1"}
        """.data(using: .utf8))
        let badPID = try #require("""
        {"port":43123,"pid":0,"launchId":"launch-1"}
        """.data(using: .utf8))

        #expect(try AgentChatSidecarStateFile.parse(badPort, token: "token", launchId: "launch-1") == nil)
        #expect(try AgentChatSidecarStateFile.parse(badPID, token: "token", launchId: "launch-1") == nil)
    }

    @Test func agentChatStateFileRequiresMatchingLaunchID() throws {
        let missing = try #require("""
        {"port":43123,"pid":9876}
        """.data(using: .utf8))
        let mismatched = try #require("""
        {"port":43123,"pid":9876,"launchId":"old-launch"}
        """.data(using: .utf8))

        #expect(try AgentChatSidecarStateFile.parse(missing, token: "token", launchId: "new-launch") == nil)
        #expect(try AgentChatSidecarStateFile.parse(mismatched, token: "token", launchId: "new-launch") == nil)
    }

    @Test func agentChatOwnedServerBuildsTokenedURLs() {
        let session = AgentChatOwnedServerSession(port: 43123, pid: 9876, token: "abc-DEF_123")

        #expect(session.browserURL.absoluteString == "http://127.0.0.1:43123/abc-DEF_123/")
        #expect(session.themeURL.absoluteString == "http://127.0.0.1:43123/abc-DEF_123/api/theme")
        #expect(AgentChatOwnedServerSession.browserURL(port: 43123, token: "abc").absoluteString == "http://127.0.0.1:43123/abc/")
    }

    @Test func agentChatStateFileStoreBuildsPerLaunchPaths() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-agent-chat-state-\(UUID().uuidString)",
            isDirectory: true
        )
        let store = AgentChatSidecarStateFileStore(
            directoryURL: root,
            fileSystem: AgentChatSidecarFileSystem()
        )

        #expect(store.stateFileURL(launchId: "launch-a").lastPathComponent == "state-launch-a.json")
        #expect(store.stateFileURL(launchId: "launch-b").lastPathComponent == "state-launch-b.json")
    }

    @Test func agentChatStateFileStoreSweepsPatternedStaleFiles() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-agent-chat-state-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let stale = root.appendingPathComponent("state-old.json")
        let unrelated = root.appendingPathComponent("other.json")
        try Data("old".utf8).write(to: stale)
        try Data("keep".utf8).write(to: unrelated)
        let oldDate = Date(timeIntervalSinceNow: -120)
        try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: stale.path)
        try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: unrelated.path)
        let store = AgentChatSidecarStateFileStore(
            directoryURL: root,
            fileSystem: AgentChatSidecarFileSystem(fileManager: fileManager)
        )

        let prepared = try #require(await store.prepareStateFileURL(
            launchId: "new",
            launchDate: Date()
        ))

        #expect(prepared.lastPathComponent == "state-new.json")
        #expect(fileManager.fileExists(atPath: prepared.path))
        #expect(!fileManager.fileExists(atPath: stale.path))
        #expect(fileManager.fileExists(atPath: unrelated.path))
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

    @Test func agentChatThemeEndpointIsRootAnchoredLikeHealthURL() throws {
        let url = try #require(URL(string: "http://127.0.0.1:7739/chat?ignored=1"))
        #expect(AgentChatThemeSync.themeURL(for: url).absoluteString == "http://127.0.0.1:7739/api/theme")
    }

    @MainActor
    @Test func agentChatThemeURLUsesTokenedOwnedServerWhenAvailable() {
        let session = AgentChatOwnedServerSession(port: 43123, pid: 9876, token: "theme-token")
        AgentChatActionInFlightGate.updateOwnedServerSession(session)
        defer { AgentChatActionInFlightGate.clearOwnedServerSession() }
        let agentChat = CmuxAgentChatConfiguration.resolved(
            local: CmuxAgentChatConfigDefinition(startCommand: "cmux-chat"),
            global: nil
        )

        #expect(AgentChatThemeSync.themeURL(for: agentChat).absoluteString == "http://127.0.0.1:43123/theme-token/api/theme")
    }

    @MainActor
    @Test func explicitAgentChatThemeURLIgnoresOwnedServer() {
        let session = AgentChatOwnedServerSession(port: 43123, pid: 9876, token: "theme-token")
        AgentChatActionInFlightGate.updateOwnedServerSession(session)
        defer { AgentChatActionInFlightGate.clearOwnedServerSession() }
        let agentChat = CmuxAgentChatConfiguration.resolved(
            local: CmuxAgentChatConfigDefinition(
                url: "http://127.0.0.1:9000/chat",
                startCommand: "cmux-chat"
            ),
            global: nil
        )

        #expect(AgentChatThemeSync.themeURL(for: agentChat).absoluteString == "http://127.0.0.1:9000/api/theme")
    }

    @MainActor
    @Test func agentChatThemeConnectionFailureClearsMatchingOwnedSession() async {
        let session = AgentChatOwnedServerSession(port: 43123, pid: 9876, token: "theme-token")
        AgentChatActionInFlightGate.updateOwnedServerSession(session)
        defer { AgentChatActionInFlightGate.clearOwnedServerSession() }

        await AgentChatThemeSync.handleThemePostFailure(
            URLError(.cannotConnectToHost),
            url: session.themeURL
        )

        #expect(AgentChatActionInFlightGate.ownedServerSession() == nil)
    }

    @MainActor
    @Test func agentChatThemeNonConnectionFailureKeepsOwnedSession() async {
        let session = AgentChatOwnedServerSession(port: 43123, pid: 9876, token: "theme-token")
        AgentChatActionInFlightGate.updateOwnedServerSession(session)
        defer { AgentChatActionInFlightGate.clearOwnedServerSession() }

        await AgentChatThemeSync.handleThemePostFailure(
            URLError(.badURL),
            url: session.themeURL
        )

        #expect(AgentChatActionInFlightGate.ownedServerSession() == session)
    }

    @Test func agentChatThemePayloadEncodesNullNullableFields() throws {
        var config = GhosttyConfig()
        config.fontFamily = " "
        config.fontSize = 0

        let data = try JSONEncoder().encode(AgentChatThemePayload(config: config))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["fontFamily"] is NSNull)
        #expect(object["fontSize"] is NSNull)
        #expect(object.keys.contains("selectionBackground"))
        #expect(object.keys.contains("cursorColor"))
    }

    @MainActor
    @Test func agentChatUIFeatureFlagDefaultsOff() throws {
        let defaultsName = "cmux-agent-chat-flag-defaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let flags = CmuxFeatureFlags(defaults: defaults, remoteFlagValueProvider: { _ in nil })

        #expect(!flags.isAgentChatUIEnabled)
    }

    @MainActor
    @Test func commandPaletteNewAgentChatContributionFollowsFeatureFlag() throws {
        try withAgentChatUIFlag(false) {
            #expect(ContentView.commandPaletteNewAgentChatContributions().isEmpty)
        }

        try withAgentChatUIFlag(true) {
            let contributions = ContentView.commandPaletteNewAgentChatContributions()
            #expect(contributions.map(\.commandId) == ["palette.newAgentChat"])
        }
    }

    @MainActor
    @Test func agentChatThemeSyncGateFollowsFeatureFlag() throws {
        try withAgentChatUIFlag(false) {
            #expect(!AgentChatThemeSync.isEnabled)
        }

        try withAgentChatUIFlag(true) {
            #expect(AgentChatThemeSync.isEnabled)
        }
    }

    @MainActor
    @Test func performNewAgentChatActionRejectsWhenFeatureFlagOff() throws {
        try withAgentChatUIFlag(false) {
            let didStart = AppDelegate().performNewAgentChatAction(
                tabManager: TabManager(),
                agentChat: .default,
                globalConfigPath: nil,
                preferredWindow: nil
            )

            #expect(!didStart)
        }
    }

    @MainActor
    @Test func performNewAgentChatActionRejectsWhenBrowserSurfacesAreDisabled() throws {
        try withAgentChatUIFlag(true) {
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
}
