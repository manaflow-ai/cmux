import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Session content width settings file", .serialized)
struct SessionContentWidthSettingsFileStoreTests {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test
    func settingsFileStoreAppliesWidthAndAlignment() throws {
        try loadSettings(maxWidthJSON: "1111", alignmentJSON: "\"right\"") { defaults in
            #expect(
                defaults.double(forKey: SessionContentWidthSettings.maxWidthKey) == 1120
            )
            #expect(
                defaults.string(forKey: SessionContentWidthSettings.alignmentKey) ==
                    SessionContentAlignment.right.rawValue
            )
        }
    }

    @Test
    func settingsFileStoreDisablesWidthCapWithFalse() throws {
        try loadSettings(maxWidthJSON: "false", alignmentJSON: "\"center\"") { defaults in
            #expect(
                defaults.double(forKey: SessionContentWidthSettings.maxWidthKey) ==
                    SessionContentWidthSettings.noMaximumWidth
            )
        }
    }

    @Test
    func settingsFileStoreAcceptsWidthAboveLegacyLimit() throws {
        try loadSettings(maxWidthJSON: "10000", alignmentJSON: "\"center\"") { defaults in
            #expect(
                defaults.double(forKey: SessionContentWidthSettings.maxWidthKey) == 10_000
            )
        }
    }

    private func loadSettings(
        maxWidthJSON: String,
        alignmentJSON: String,
        verify: (UserDefaults) throws -> Void
    ) throws {
        let defaults = UserDefaults.standard
        try preservingDefaults(keys: [
            SessionContentWidthSettings.maxWidthKey,
            SessionContentWidthSettings.alignmentKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try """
            {
              "terminal": {
                "sessionContentMaxWidth": \(maxWidthJSON),
                "sessionContentAlignment": \(alignmentJSON)
              }
            }
            """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            try verify(defaults)
        }
    }

    private func preservingDefaults(keys: [String], _ body: () throws -> Void) throws {
        let defaults = UserDefaults.standard
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        for key in keys { defaults.removeObject(forKey: key) }
        defer {
            for (key, value) in saved {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        try body()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-session-content-width-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite("Session content width presentation")
struct SessionContentWidthPresentationTests {
    private let bounds = CGRect(x: 10, y: 20, width: 1000, height: 600)

    @Test
    func disabledPresentationUsesFullPaneBounds() {
        #expect(SessionContentWidthPresentation.disabled.contentFrame(in: bounds) == bounds)
    }

    @Test(arguments: [
        (SessionContentAlignment.left, 10.0),
        (SessionContentAlignment.center, 210.0),
        (SessionContentAlignment.right, 410.0),
    ])
    func cappedPresentationAlignsInsidePane(
        alignment: SessionContentAlignment,
        expectedX: CGFloat
    ) {
        let presentation = SessionContentWidthPresentation(
            storedMaximumWidth: 600,
            storedAlignment: alignment.rawValue
        )

        #expect(
            presentation.contentFrame(in: bounds) ==
                CGRect(x: expectedX, y: 20, width: 600, height: 600)
        )
    }

    @Test
    func narrowPaneUsesFullPaneBounds() {
        let presentation = SessionContentWidthPresentation(
            storedMaximumWidth: 1200,
            storedAlignment: SessionContentAlignment.right.rawValue
        )

        #expect(presentation.contentFrame(in: bounds) == bounds)
    }
}
