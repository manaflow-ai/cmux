import Testing
import Foundation
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct BrowserDevHostCachePolicyTests {
    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "BrowserDevHostCachePolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func devHostsMatchBuiltInList() {
        #expect(BrowserDevHostCachePolicy.isDevHost("localhost"))
        #expect(BrowserDevHostCachePolicy.isDevHost("app.localhost"))
        #expect(BrowserDevHostCachePolicy.isDevHost("127.0.0.1"))
        #expect(BrowserDevHostCachePolicy.isDevHost("::1"))
        #expect(BrowserDevHostCachePolicy.isDevHost("0.0.0.0"))
        #expect(BrowserDevHostCachePolicy.isDevHost("myapp.localtest.me"))
    }

    @Test func nonDevHostsDoNotMatch() {
        #expect(!BrowserDevHostCachePolicy.isDevHost("example.com"))
        #expect(!BrowserDevHostCachePolicy.isDevHost("localhost.evil.com"))
        #expect(!BrowserDevHostCachePolicy.isDevHost("mylocalhost"))
        #expect(!BrowserDevHostCachePolicy.isDevHost(""))
        #expect(!BrowserDevHostCachePolicy.isDevHost(nil))
    }

    @Test func enabledByDefaultAndDisableHonored() {
        let defaults = isolatedDefaults()
        #expect(BrowserDevHostCachePolicy.isEnabled(defaults: defaults))
        defaults.set(false, forKey: BrowserDevHostCachePolicy.enabledKey)
        #expect(!BrowserDevHostCachePolicy.isEnabled(defaults: defaults))
        defaults.set(true, forKey: BrowserDevHostCachePolicy.enabledKey)
        #expect(BrowserDevHostCachePolicy.isEnabled(defaults: defaults))
    }

    @Test func configKeyDisablesFetchThroughManagedDefaults() {
        let defaults = isolatedDefaults()
        // Simulate what KeyboardShortcutSettingsFileStore does when it parses
        // {"browser": {"disableCacheForDevHosts": false}} — it writes
        // .bool(false) to managedUserDefaults[BrowserDevHostCachePolicy.enabledKey].
        // The runtime then reads that key from UserDefaults.
        #expect(BrowserDevHostCachePolicy.enabledKey == "browserDisableCacheForDevHosts")
        defaults.set(false, forKey: BrowserDevHostCachePolicy.enabledKey)
        #expect(!BrowserDevHostCachePolicy.isEnabled(defaults: defaults))
        #expect(!BrowserDevHostCachePolicy.shouldBypassCache(
            for: URL(string: "http://localhost:3000"), defaults: defaults))
    }

    @Test func shouldBypassCacheDecisions() {
        let defaults = isolatedDefaults()
        #expect(BrowserDevHostCachePolicy.shouldBypassCache(
            for: URL(string: "http://localhost:3000/app"), defaults: defaults))
        #expect(BrowserDevHostCachePolicy.shouldBypassCache(
            for: URL(string: "https://app.localhost/x"), defaults: defaults))
        #expect(!BrowserDevHostCachePolicy.shouldBypassCache(
            for: URL(string: "https://example.com"), defaults: defaults))
        #expect(!BrowserDevHostCachePolicy.shouldBypassCache(
            for: URL(string: "file:///tmp/page.html"), defaults: defaults))
        #expect(!BrowserDevHostCachePolicy.shouldBypassCache(for: nil, defaults: defaults))

        defaults.set(false, forKey: BrowserDevHostCachePolicy.enabledKey)
        #expect(!BrowserDevHostCachePolicy.shouldBypassCache(
            for: URL(string: "http://localhost:3000"), defaults: defaults))
    }
}
