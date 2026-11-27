import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct TextBoxSubmitActionSettingsFileTests {
    private let backupsKey = "cmux.settingsFile.backups.v1"
    private let importedKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test
    func testSettingsFileStoreRejectsInvalidTextBoxSubmitActions() throws {
        let defaults = UserDefaults.standard
        let key = TerminalTextBoxInputSettings.submitActionsKey
        try preservingDefaults(keys: [key, backupsKey, importedKey]) {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: backupsKey)
            defaults.removeObject(forKey: importedKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }
            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try writeSettingsFile(
                """
                {
                  "terminal": {
                    "textBoxSubmitActions": [{
                      "id": "bad",
                      "title": "Bad",
                      "kind": "commandTemplate",
                      "commandTemplate": "router --prompt '{{prompt}}'",
                      "systemImage": "sparkles"
                    }]
                  }
                }
                """,
                to: settingsFileURL
            )

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            #expect(defaults.object(forKey: key) == nil)
            #expect(
                TerminalTextBoxInputSettings.submitActions(defaults: defaults).map(\.id) ==
                    TerminalTextBoxInputSettings.submitActions(configuredJSON: nil).map(\.id)
            )
        }
    }

    @Test
    func testCommandTemplateSubmitButtonDisablesWhenSubmitWouldFailClosed() throws {
        let codex = try #require(TextBoxSubmitAction.builtInActions.first { $0.id == "codex" })
        #expect(!TextBoxInputContainer.shouldEnableSubmitButton(
            baseCanSend: true,
            pendingProviderLaunchAction: nil,
            action: codex,
            shouldForceTextEntrySubmit: false,
            allowsCommandTemplateSubmit: false
        ))
        #expect(TextBoxInputContainer.shouldEnableSubmitButton(
            baseCanSend: true,
            pendingProviderLaunchAction: nil,
            action: codex,
            shouldForceTextEntrySubmit: false,
            allowsCommandTemplateSubmit: true
        ))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-textbox-submit-actions-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSettingsFile(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func preservingDefaults(keys: [String], _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previousValues = keys.map { (key: $0, value: defaults.object(forKey: $0)) }
        defer {
            for previous in previousValues {
                if let value = previous.value {
                    defaults.set(value, forKey: previous.key)
                } else {
                    defaults.removeObject(forKey: previous.key)
                }
            }
        }
        try body()
    }
}
