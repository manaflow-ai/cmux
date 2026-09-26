import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct BrowserTrackingPreventionSettingsTests {
    @Test(arguments: [false, true], [false, true])
    func browserConfigurationPreservesTheStoreAndAppliesOnlyAnExplicitOptOut(
        disabled: Bool,
        initialTrackingPreventionEnabled: Bool
    ) throws {
        let suiteName = "BrowserTrackingPreventionSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        if disabled {
            defaults.set(true, forKey: "browserDisableTrackingPrevention")
        }

        let profileID = UUID()
        let store = WKWebsiteDataStore(forIdentifier: profileID)
        defer { WKWebsiteDataStore.remove(forIdentifier: profileID) { _ in } }
        let getter = NSSelectorFromString("_resourceLoadStatisticsEnabled")
        let setter = NSSelectorFromString("_setResourceLoadStatisticsEnabled:")
        try #require(store.responds(to: getter) && store.responds(to: setter))
        typealias GetEnabled = @convention(c) (AnyObject, Selector) -> Bool
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Void
        let getEnabled = unsafeBitCast(try #require(store.method(for: getter)), to: GetEnabled.self)
        let setEnabled = unsafeBitCast(try #require(store.method(for: setter)), to: SetEnabled.self)
        setEnabled(store, setter, initialTrackingPreventionEnabled)
        try #require(getEnabled(store, getter) == initialTrackingPreventionEnabled)

        let configuration = WKWebViewConfiguration()
        BrowserPanel.configureWebViewConfiguration(configuration, websiteDataStore: store, defaults: defaults)

        #expect(configuration.websiteDataStore === store)
        #expect(store.identifier == profileID)
        #expect(store.isPersistent)
        #expect(getEnabled(store, getter) == (disabled ? false : initialTrackingPreventionEnabled))
    }

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

        try #"{"browser":{"disableTrackingPrevention":"true"}}"#
            .write(to: configURL, atomically: true, encoding: .utf8)
        store.reload()
        #expect(defaults.object(forKey: "browserDisableTrackingPrevention") == nil)
    }
}
