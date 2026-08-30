import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Video background settings file", .serialized)
struct VideoBackgroundSettingsFileStoreTests {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test
    func settingsFileStoreAppliesVideoBackgroundSection() throws {
        try loadVideoBackgroundSection(
            """
            {
              "enabled": true,
              "source": "  https://www.youtube.com/watch?v=dQw4w9WgXcQ  ",
              "queue": [" first ", "second"],
              "quality": "4k",
              "volume": 0.35,
              "muted": false,
              "dimOpacity": 0.6
            }
            """
        ) { defaults in
            #expect(defaults.object(forKey: VideoBackgroundSettings.enabledKey) as? Bool == true)
            #expect(
                defaults.object(forKey: VideoBackgroundSettings.sourceKey) as? String ==
                    "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
            )
            #expect(defaults.object(forKey: VideoBackgroundSettings.dimOpacityKey) as? Double == 0.6)
            #expect(defaults.object(forKey: VideoBackgroundSettings.mutedKey) as? Bool == false)
            #expect(defaults.array(forKey: VideoBackgroundSettings.queueKey) as? [String] == ["first", "second"])
            #expect(defaults.string(forKey: VideoBackgroundSettings.qualityKey) == "2160p")
            #expect(defaults.object(forKey: VideoBackgroundSettings.volumeKey) as? Double == 0.35)
        }
    }

    @Test
    func settingsFileStoreClampsOutOfRangeVideoBackgroundDimOpacity() throws {
        try loadVideoBackgroundSection(
            """
            { "dimOpacity": 3.5 }
            """
        ) { defaults in
            #expect(
                defaults.object(forKey: VideoBackgroundSettings.dimOpacityKey) as? Double ==
                    VideoBackgroundSettings.maximumDimOpacity
            )
        }
    }

    @Test
    func settingsFileStoreIgnoresInvalidVideoBackgroundValues() throws {
        try loadVideoBackgroundSection(
            """
            {
              "enabled": "yes",
              "source": 42,
              "queue": ["ok", 42],
              "quality": "8k",
              "volume": "loud",
              "dimOpacity": "dark"
            }
            """
        ) { defaults in
            #expect(defaults.object(forKey: VideoBackgroundSettings.enabledKey) == nil)
            #expect(defaults.object(forKey: VideoBackgroundSettings.sourceKey) == nil)
            #expect(defaults.object(forKey: VideoBackgroundSettings.dimOpacityKey) == nil)
            #expect(defaults.object(forKey: VideoBackgroundSettings.queueKey) == nil)
            #expect(defaults.object(forKey: VideoBackgroundSettings.qualityKey) == nil)
            #expect(defaults.object(forKey: VideoBackgroundSettings.volumeKey) == nil)
        }
    }

    private func loadVideoBackgroundSection(_ sectionJSON: String, verify: (UserDefaults) throws -> Void) throws {
        let defaults = UserDefaults.standard
        try preservingDefaults(keys: [
            VideoBackgroundSettings.enabledKey,
            VideoBackgroundSettings.sourceKey,
            VideoBackgroundSettings.dimOpacityKey,
            VideoBackgroundSettings.queueKey,
            VideoBackgroundSettings.qualityKey,
            VideoBackgroundSettings.volumeKey,
            VideoBackgroundSettings.mutedKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try """
            {
              "terminal": {
                "videoBackground": \(sectionJSON)
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
            "cmux-video-background-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
