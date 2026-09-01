import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct CmuxConfigNamedColorTests {
    private func decode(_ json: String, colorDefaults: UserDefaults? = nil) throws -> CmuxConfigFile {
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        if let colorDefaults {
            decoder.userInfo[.cmuxWorkspaceColorDefaults] = colorDefaults
        }
        return try decoder.decode(CmuxConfigFile.self, from: data)
    }

    @Test func decodeWorkspaceCommandAcceptsNamedColor() throws {
        let suiteName = "cmux-config-named-color-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        WorkspaceTabColorSettings.persistPaletteMap(["Indigo": "#283593"], defaults: defaults)

        let json = """
        {
          "commands": [{
            "name": "Dev env",
            "workspace": {
              "name": "Development",
              "color": "Indigo"
            }
          }]
        }
        """
        let config = try decode(json, colorDefaults: defaults)
        #expect(config.commands[0].workspace?.color == "#283593")
    }

    @Test func decodeWorkspaceCommandReportsUnknownNamedColorAndSkipsEntry() throws {
        let suiteName = "cmux-config-unknown-color-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let json = """
        {
          "commands": [{
            "name": "Dev env",
            "workspace": {
              "name": "Development",
              "color": "Definitely Not A Palette Color"
            }
          }]
        }
        """
        let config = try decode(json, colorDefaults: defaults)
        #expect(config.commands.isEmpty)
        #expect(config.commandDecodingIssues.count == 1)
    }

    @MainActor
    @Test func configParseCacheInvalidatesWhenWorkspaceColorPaletteChanges() throws {
        let defaultsSuite = "cmux-config-store-colors-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json")
        let json = """
        {
          "commands": [{
            "name": "Dev env",
            "workspace": {
              "name": "Development",
              "color": "Codex Test"
            }
          }]
        }
        """
        try json.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: configURL.path,
            startFileWatchers: false,
            workspaceColorDefaults: defaults
        )
        WorkspaceTabColorSettings.persistPaletteMap(["Codex Test": "#111111"], defaults: defaults)
        store.loadAll()
        #expect(store.loadedCommands.first?.workspace?.color == "#111111")

        WorkspaceTabColorSettings.persistPaletteMap(["Codex Test": "#222222"], defaults: defaults)
        store.loadAll()
        #expect(store.loadedCommands.first?.workspace?.color == "#222222")
    }
}
