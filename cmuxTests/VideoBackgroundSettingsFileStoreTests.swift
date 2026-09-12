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
    @Test
    @MainActor
    func configurationPreparationImportsTheNewQueueBeforePlaybackSelection() throws {
        let suiteName = "VideoBackgroundReloadOrder.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cmux.json")
        let editor = VideoBackgroundConfigEditor(fileURL: url)
        _ = try editor.update(.init(source: "/tmp/first.mp4", queue: ["/tmp/first.mp4", "/tmp/second.mp4"]))
        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: url.path, fallbackPath: nil, additionalFallbackPaths: [],
            userDefaults: defaults, startWatching: false
        )
        let policy = VideoBackgroundSettings()
        let coordinator = VideoBackgroundPlaybackCoordinator()
        _ = coordinator.configure(sourceTexts: policy.effectiveSourceTexts(defaults: defaults), quality: "1080p")
        _ = try editor.update(.init(source: "/tmp/second.mp4", queue: ["/tmp/second.mp4", "/tmp/first.mp4"]))
        #expect(policy.effectiveSourceTexts(defaults: defaults).first == "/tmp/first.mp4")

        _ = TerminalFontConfigurationReloadTransaction.prepare(
            appliedMagnificationPercent: 100,
            reloadSettings: { _ = store.reload() },
            storedMagnificationPercent: { 100 }
        )
        let selected = coordinator.configure(
            sourceTexts: policy.effectiveSourceTexts(defaults: defaults), quality: "1080p", restart: true
        )
        #expect(policy.effectiveSourceTexts(defaults: defaults).first == "/tmp/second.mp4")
        #expect(selected.index == 0)
        #expect(selected.currentSource == .localFile(url: URL(fileURLWithPath: "/tmp/second.mp4")))
    }

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
        let suiteName = "VideoBackgroundSettingsFileStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

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
            userDefaults: defaults,
            startWatching: false
        )

        try verify(defaults)
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
