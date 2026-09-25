import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct BrowserTrackingPreventionSettingsTests {
    @Test
    func configurationCanOptOutAndRestoreTrackingPrevention() throws {
        let suiteName = "BrowserTrackingPreventionSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        let configURL = directory.appendingPathComponent("cmux.json")
        try #"{"browser":{"disableTrackingPrevention":true}}"#
            .write(to: configURL, atomically: true, encoding: .utf8)
        let store = CmuxSettingsFileStore(
            primaryPath: configURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            notificationCenter: NotificationCenter(),
            userDefaults: defaults,
            startWatching: false,
            isUserDefaultsKeyForcedByProfile: { _ in false }
        )

        #expect(defaults.object(forKey: "browserDisableTrackingPrevention") as? Bool == true)

        try #"{"browser":{"disableTrackingPrevention":false}}"#
            .write(to: configURL, atomically: true, encoding: .utf8)
        store.reload()
        #expect(defaults.object(forKey: "browserDisableTrackingPrevention") as? Bool == false)

        try #"{"browser":{}}"#.write(to: configURL, atomically: true, encoding: .utf8)
        store.reload()
        #expect(defaults.object(forKey: "browserDisableTrackingPrevention") == nil)
    }
}
