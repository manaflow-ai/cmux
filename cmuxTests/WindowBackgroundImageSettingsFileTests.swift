import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// cmux.json coverage for the `windowBackground` section: the image the main
/// window draws behind every surface, its opacity and its fit.
@Suite("Window background image settings file", .serialized)
struct WindowBackgroundImageSettingsFileTests {
    private static let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private static let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"
    private static let keys = [
        WindowBackgroundImageSettings.pathDefaultsKey,
        WindowBackgroundImageSettings.opacityDefaultsKey,
        WindowBackgroundImageSettings.fitDefaultsKey,
        settingsFileBackupsDefaultsKey,
        importedManagedDefaultsKey,
    ]

    @Test
    func appliesImageOpacityAndFit() throws {
        try loadSettingsFile(
            """
            {
              "windowBackground": {
                "image": "~/Pictures/wall.jpg",
                "imageOpacity": 0.4,
                "imageFit": "contain"
              }
            }
            """
        ) { defaults in
            #expect(WindowBackgroundImageSettings.load(from: defaults) == WindowBackgroundImageSettings(
                path: "~/Pictures/wall.jpg",
                opacity: 0.4,
                fit: .contain
            ))
        }
    }

    @Test
    func clampsOpacityAndRejectsRelativePathAndUnknownFitIndependently() throws {
        try loadSettingsFile(
            """
            {
              "windowBackground": {
                "image": "Pictures/wall.jpg",
                "imageOpacity": 3,
                "imageFit": "tile"
              }
            }
            """
        ) { defaults in
            #expect(defaults.object(forKey: WindowBackgroundImageSettings.pathDefaultsKey) == nil)
            #expect(defaults.object(forKey: WindowBackgroundImageSettings.fitDefaultsKey) == nil)
            #expect(defaults.double(forKey: WindowBackgroundImageSettings.opacityDefaultsKey) == 1)
            #expect(!WindowBackgroundImageSettings.load(from: defaults).isEnabled)
        }
    }

    @Test
    func nullImageTurnsTheImageOff() throws {
        try loadSettingsFile(
            """
            {
              "windowBackground": {
                "image": null
              }
            }
            """,
            seed: { $0.set("/tmp/old.png", forKey: WindowBackgroundImageSettings.pathDefaultsKey) }
        ) { defaults in
            #expect(defaults.string(forKey: WindowBackgroundImageSettings.pathDefaultsKey) == "")
            #expect(!WindowBackgroundImageSettings.load(from: defaults).isEnabled)
        }
    }

    private func loadSettingsFile(
        _ contents: String,
        seed: (UserDefaults) -> Void = { _ in },
        verify: (UserDefaults) -> Void
    ) throws {
        let defaults = UserDefaults.standard
        let saved = Self.keys.map { ($0, defaults.object(forKey: $0)) }
        for key in Self.keys { defaults.removeObject(forKey: key) }
        defer {
            for (key, value) in saved {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        seed(defaults)

        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-window-background-settings-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try contents.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        verify(defaults)
    }
}
