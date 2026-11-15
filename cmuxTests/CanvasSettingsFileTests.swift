import CmuxCanvas
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `canvas.paneGap` and `canvas.snappingEnabled` in cmux.json must reach the
/// metrics the canvas layout runs on (#13993).
@Suite("Canvas settings file")
struct CanvasSettingsFileTests {
    @Test(arguments: ["0", "40", "40.0", "64"])
    func canvasKeysReachRuntimeMetrics(gap: String) throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.writePrimary("""
        {
          // cmux.json is JSONC, so the canvas section is read through that path.
          "canvas": { "paneGap": \(gap), "snappingEnabled": false }
        }
        """)

        _ = fixture.makeStore()

        let expectedGap = try #require(Double(gap))
        #expect(fixture.metrics.gap == expectedGap)
        #expect(fixture.metrics.snapThreshold == 0)
        let settings = UserDefaultsSettingsClient(defaults: fixture.defaults)
        #expect(settings.value(for: fixture.catalog.paneGap) == Int(expectedGap))
        #expect(settings.value(for: fixture.catalog.snappingEnabled) == false)
    }

    @Test
    func reloadFollowsTheFileAndRemovalRestoresThePriorPreference() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        fixture.defaults.set(7, forKey: fixture.catalog.paneGap.userDefaultsKey)
        fixture.defaults.set(true, forKey: fixture.catalog.snappingEnabled.userDefaultsKey)
        try fixture.writePrimary(#"{"canvas":{"paneGap":40,"snappingEnabled":false}}"#)

        let store = fixture.makeStore()
        #expect(fixture.metrics.gap == 40)
        #expect(fixture.metrics.snapThreshold == 0)

        try fixture.writePrimary(#"{"canvas":{"paneGap":0,"snappingEnabled":true}}"#)
        store.reload()
        #expect(fixture.metrics.gap == 0)
        #expect(fixture.metrics.snapThreshold == CanvasMetrics.defaultSnapThreshold)

        try fixture.writePrimary("{}")
        store.reload()
        #expect(fixture.metrics.gap == 7)
        #expect(fixture.defaults.object(forKey: fixture.catalog.snappingEnabled.userDefaultsKey) as? Bool == true)
    }

    @Test
    func removingTheSectionLeavesNoImportedValueBehind() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.writePrimary(#"{"canvas":{"paneGap":40,"snappingEnabled":false}}"#)

        let store = fixture.makeStore()
        #expect(fixture.metrics.gap == 40)
        #expect(fixture.metrics.snapThreshold == 0)

        try fixture.writePrimary("{}")
        store.reload()
        #expect(fixture.defaults.object(forKey: fixture.catalog.paneGap.userDefaultsKey) == nil)
        #expect(fixture.defaults.object(forKey: fixture.catalog.snappingEnabled.userDefaultsKey) == nil)
        #expect(fixture.metrics.gap == CanvasMetrics.defaultGap)
        #expect(fixture.metrics.snapThreshold == CanvasMetrics.defaultSnapThreshold)
    }

    /// Out of range, fractional, mistyped and oversized values must not land in
    /// the setting, and must not stop the sibling key from being read.
    @Test(arguments: ["-1", "65", "1.5", "true", "\"40\"", "null", "{}", "[]", "1e100", "18446744073709551616"])
    func invalidPaneGapKeepsThePreferenceAndStillReadsSnapping(gap: String) throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        fixture.defaults.set(7, forKey: fixture.catalog.paneGap.userDefaultsKey)
        try fixture.writePrimary("{\"canvas\":{\"paneGap\":\(gap),\"snappingEnabled\":false}}")

        _ = fixture.makeStore()

        #expect(fixture.metrics.gap == 7)
        #expect(fixture.metrics.snapThreshold == 0)
    }

    /// Only a JSON boolean is a snapping value: `0`, `1` and `"false"` are not.
    @Test(arguments: ["0", "1", "\"false\"", "\"true\"", "null", "{}", "[]"], [true, false])
    func invalidSnappingKeepsThePreferenceAndStillReadsPaneGap(snapping: String, prior: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        fixture.defaults.set(prior, forKey: fixture.catalog.snappingEnabled.userDefaultsKey)
        try fixture.writePrimary("{\"canvas\":{\"paneGap\":40,\"snappingEnabled\":\(snapping)}}")

        _ = fixture.makeStore()

        #expect(fixture.metrics.gap == 40)
        #expect(fixture.defaults.object(forKey: fixture.catalog.snappingEnabled.userDefaultsKey) as? Bool == prior)
    }

    @Test
    func primaryAndFallbackFilesMergePerKey() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.writeFallback(#"{"canvas":{"paneGap":8,"snappingEnabled":false}}"#)
        try fixture.writePrimary(#"{"canvas":{"paneGap":28}}"#)

        _ = fixture.makeStore(usesFallback: true)

        #expect(fixture.metrics.gap == 28)
        #expect(fixture.metrics.snapThreshold == 0)
    }

    @Test
    func invalidPrimaryValueFallsThroughToTheFallbackFile() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.writeFallback(#"{"canvas":{"paneGap":8,"snappingEnabled":false}}"#)
        try fixture.writePrimary(#"{"canvas":{"paneGap":65,"snappingEnabled":true}}"#)

        _ = fixture.makeStore(usesFallback: true)

        #expect(fixture.metrics.gap == 8)
        #expect(fixture.metrics.snapThreshold == CanvasMetrics.defaultSnapThreshold)
    }

    /// The store keeps its last good file when an edit introduces an invalid
    /// value, so a bad canvas value must not drop the values already in effect.
    @Test
    func invalidEditOnReloadKeepsTheValuesInEffect() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.writePrimary(#"{"canvas":{"paneGap":28,"snappingEnabled":false}}"#)
        let store = fixture.makeStore()
        #expect(fixture.metrics.gap == 28)

        try fixture.writePrimary(#"{"canvas":{"paneGap":65,"snappingEnabled":true}}"#)
        store.reload()

        #expect(fixture.metrics.gap == 28)
        #expect(fixture.metrics.snapThreshold == 0)
    }

    /// A `canvas` value that is not an object is a mistake to report, not a
    /// removed section: the values already in effect must stay.
    @Test(arguments: ["false", "null", "[]", "\"wide\"", "3"])
    func malformedSectionOnReloadKeepsTheValuesInEffect(section: String) throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.writePrimary(#"{"canvas":{"paneGap":28,"snappingEnabled":false}}"#)
        let store = fixture.makeStore()
        #expect(fixture.metrics.gap == 28)

        try fixture.writePrimary("{\"canvas\":\(section)}")
        store.reload()

        #expect(fixture.metrics.gap == 28)
        #expect(fixture.metrics.snapThreshold == 0)
    }

    /// An isolated settings file, fallback file and defaults suite, so the test
    /// never reads or writes the developer's own cmux.json or preferences.
    private struct Fixture {
        let suiteName = "CanvasSettingsFileTests.\(UUID().uuidString)"
        let directory: URL
        let defaults: UserDefaults
        let catalog = CanvasCatalogSection()

        var metrics: CanvasMetrics { CanvasLayoutSettings.currentMetrics(defaults: defaults) }
        private var primaryURL: URL { directory.appendingPathComponent("cmux.json") }
        private var fallbackURL: URL { directory.appendingPathComponent("settings.json") }

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suiteName))
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(suiteName, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func writePrimary(_ contents: String) throws {
            try Data(contents.utf8).write(to: primaryURL)
        }

        func writeFallback(_ contents: String) throws {
            try Data(contents.utf8).write(to: fallbackURL)
        }

        func makeStore(usesFallback: Bool = false) -> CmuxSettingsFileStore {
            CmuxSettingsFileStore(
                primaryPath: primaryURL.path,
                fallbackPath: usesFallback ? fallbackURL.path : nil,
                additionalFallbackPaths: [],
                notificationCenter: NotificationCenter(),
                userDefaults: defaults,
                languageSettingsStore: LanguageSettingsStore(defaults: defaults, domainName: suiteName),
                passwordStore: SocketControlPasswordStore(
                    environment: [:],
                    fileURL: directory.appendingPathComponent("socket-password"),
                    loadKeychainPassword: { nil },
                    deleteKeychainPassword: { true }
                ),
                startWatching: false,
                isUserDefaultsKeyForcedByProfile: { _ in false }
            )
        }

        func tearDown() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
