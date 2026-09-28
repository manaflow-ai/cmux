import CmuxCanvas
import Foundation
import Testing
import struct CmuxSettings.CanvasCatalogSection
import struct CmuxSettings.SocketControlPasswordStore
import struct CmuxSettings.UserDefaultsSettingsClient

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Canvas settings file")
final class CanvasSettingsFileTests {
    private let suiteName = "CanvasSettingsFileTests.\(UUID().uuidString)"
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("canvas-settings-\(UUID().uuidString)", isDirectory: true)
    private let defaults: UserDefaults
    private let catalog = CanvasCatalogSection()

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test(arguments: ["0", "40", "40.0", "64"])
    func importsCanvasValuesIntoSettingsAndRuntimeMetrics(gap: String) throws {
        try write("""
        {
          // Exercise the JSONC ingestion path used by cmux.json.
          "canvas": { "paneGap": \(gap), "snappingEnabled": false }
        }
        """)
        _ = makeStore()

        let metrics = CanvasLayoutSettings.currentMetrics(defaults: defaults)
        #expect(metrics.gap == Double(gap)!)
        #expect(metrics.snapThreshold == 0)
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        #expect(settings.value(for: catalog.paneGap) == Int(Double(gap)!))
        #expect(settings.value(for: catalog.snappingEnabled) == false)
    }

    @Test
    func reloadUpdatesValuesAndRemovingKeysRestoresPriorSettings() throws {
        defaults.set(7, forKey: catalog.paneGap.userDefaultsKey)
        defaults.set(true, forKey: catalog.snappingEnabled.userDefaultsKey)
        try write(#"{"canvas":{"paneGap":40,"snappingEnabled":false}}"#)
        let store = makeStore()
        #expect(CanvasLayoutSettings.currentMetrics(defaults: defaults).gap == 40)
        #expect(CanvasLayoutSettings.currentMetrics(defaults: defaults).snapThreshold == 0)

        try write(#"{"canvas":{"paneGap":0,"snappingEnabled":true}}"#)
        store.reload()
        #expect(CanvasLayoutSettings.currentMetrics(defaults: defaults).gap == 0)
        #expect(CanvasLayoutSettings.currentMetrics(defaults: defaults).snapThreshold == CanvasMetrics.defaultSnapThreshold)

        try write("{}")
        store.reload()
        #expect(CanvasLayoutSettings.currentMetrics(defaults: defaults).gap == 7)
        #expect(defaults.object(forKey: catalog.snappingEnabled.userDefaultsKey) as? Bool == true)
    }

    @Test
    func removingCanvasRestoresAbsentDefaults() throws {
        try write(#"{"canvas":{"paneGap":40,"snappingEnabled":false}}"#)
        let store = makeStore()
        #expect(CanvasLayoutSettings.currentMetrics(defaults: defaults).gap == 40)

        try write("{}")
        store.reload()
        #expect(defaults.object(forKey: catalog.paneGap.userDefaultsKey) == nil)
        #expect(defaults.object(forKey: catalog.snappingEnabled.userDefaultsKey) == nil)
        #expect(CanvasLayoutSettings.currentMetrics(defaults: defaults).gap == CanvasMetrics.defaultGap)
        #expect(CanvasLayoutSettings.currentMetrics(defaults: defaults).snapThreshold == CanvasMetrics.defaultSnapThreshold)
    }

    @Test(arguments: ["-1", "65", "1.5", "true", "\"40\"", "null", "{}", "[]", "1e100", "18446744073709551616"])
    func invalidGapLeavesPreferenceUntouchedAndStillImportsSnapping(gap: String) throws {
        defaults.set(7, forKey: catalog.paneGap.userDefaultsKey)
        try write("{\"canvas\":{\"paneGap\":\(gap),\"snappingEnabled\":false}}")
        _ = makeStore()

        #expect(CanvasLayoutSettings.currentMetrics(defaults: defaults).gap == 7)
        #expect(CanvasLayoutSettings.currentMetrics(defaults: defaults).snapThreshold == 0)
    }

    @Test(arguments: ["0", "1", "\"false\"", "null", "{}", "[]"])
    func invalidSnappingLeavesPreferenceUntouchedAndStillImportsGap(snapping: String) throws {
        defaults.set(false, forKey: catalog.snappingEnabled.userDefaultsKey)
        try write("{\"canvas\":{\"paneGap\":40,\"snappingEnabled\":\(snapping)}}")
        _ = makeStore()

        #expect(CanvasLayoutSettings.currentMetrics(defaults: defaults).gap == 40)
        #expect(CanvasLayoutSettings.currentMetrics(defaults: defaults).snapThreshold == 0)
    }

    @Test
    func primaryAndFallbackMergePerSetting() throws {
        let fallback = directory.appendingPathComponent("settings.json")
        try #"{"canvas":{"paneGap":8,"snappingEnabled":false}}"#
            .write(to: fallback, atomically: true, encoding: .utf8)
        try write(#"{"canvas":{"paneGap":28}}"#)
        let store = makeStore(fallback: fallback)
        #expect(CanvasLayoutSettings.currentMetrics(defaults: defaults).gap == 28)
        #expect(CanvasLayoutSettings.currentMetrics(defaults: defaults).snapThreshold == 0)

        try write(#"{"canvas":{"paneGap":65,"snappingEnabled":true}}"#)
        store.reload()
        #expect(CanvasLayoutSettings.currentMetrics(defaults: defaults).gap == 8)
        #expect(CanvasLayoutSettings.currentMetrics(defaults: defaults).snapThreshold == CanvasMetrics.defaultSnapThreshold)
    }

    private func write(_ contents: String) throws {
        try contents.write(to: directory.appendingPathComponent("cmux.json"), atomically: true, encoding: .utf8)
    }

    private func makeStore(fallback: URL? = nil) -> CmuxSettingsFileStore {
        CmuxSettingsFileStore(
            primaryPath: directory.appendingPathComponent("cmux.json").path,
            fallbackPath: fallback?.path,
            additionalFallbackPaths: [],
            notificationCenter: NotificationCenter(),
            userDefaults: defaults,
            passwordStore: SocketControlPasswordStore(environment: [:], fileURL: directory.appendingPathComponent("password")),
            startWatching: false,
            isUserDefaultsKeyForcedByProfile: { _ in false }
        )
    }
}
