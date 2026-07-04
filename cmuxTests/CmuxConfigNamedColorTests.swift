import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("cmux config named color decoding", .serialized)
struct CmuxConfigNamedColorTests {
    private func decode(_ json: String, colorDefaults: UserDefaults? = nil) throws -> CmuxConfigFile {
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        if let colorDefaults {
            decoder.userInfo[.cmuxWorkspaceColorDefaults] = colorDefaults
        }
        return try decoder.decode(CmuxConfigFile.self, from: data)
    }

    @Test("Workspace command accepts a named palette color")
    func decodeWorkspaceCommandAcceptsNamedColor() throws {
        let suiteName = "cmux-config-named-color-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        WorkspaceTabColorPaletteStore(defaults: defaults).persistPaletteMap(["Indigo": "#283593"])

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

    @Test("Workspace command rejects an unknown named color")
    func decodeWorkspaceCommandRejectsUnknownNamedColor() {
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
        #expect(throws: (any Error).self) {
            _ = try decode(json, colorDefaults: defaults)
        }
    }

    @MainActor
    @Test("Config parse cache invalidates when the workspace color palette changes")
    func configParseCacheInvalidatesWhenWorkspaceColorPaletteChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-config-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let colorStore = WorkspaceTabColorPaletteStore()
        let previousPalette = UserDefaults.standard.dictionary(forKey: colorStore.paletteKey)
        defer {
            if let previousPalette {
                UserDefaults.standard.set(previousPalette, forKey: colorStore.paletteKey)
            } else {
                UserDefaults.standard.removeObject(forKey: colorStore.paletteKey)
            }
        }

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

        let store = CmuxConfigStore(globalConfigPath: configURL.path, startFileWatchers: false)
        colorStore.persistPaletteMap(["Codex Test": "#111111"])
        store.loadAll()
        #expect(store.loadedCommands.first?.workspace?.color == "#111111")

        colorStore.persistPaletteMap(["Codex Test": "#222222"])
        store.loadAll()
        #expect(store.loadedCommands.first?.workspace?.color == "#222222")
    }
}
