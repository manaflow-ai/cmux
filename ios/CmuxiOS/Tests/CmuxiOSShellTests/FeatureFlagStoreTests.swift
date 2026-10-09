import CmuxiOSShell
import Foundation
import Testing

@MainActor
@Suite struct FeatureFlagStoreTests {
    private func defaults() -> UserDefaults {
        let name = "a1.flags." + UUID().uuidString
        return UserDefaults(suiteName: name)!
    }

    @Test func releaseShowsShippedCoreTabs() {
        let store = FeatureFlagStore(environment: [:], defaults: defaults(), isDebug: false)
        #expect(store.visibleTabs == [.home, .feed, .workspaces, .compose, .hosts, .search, .cloud, .settings])
    }

    @Test func debugShowsEveryTabInOrder() {
        let store = FeatureFlagStore(environment: [:], defaults: defaults(), isDebug: true)
        #expect(store.visibleTabs == ShellTab.allCases)
    }

    @Test func environmentWinsOverDeviceOverride() {
        let store = FeatureFlagStore(environment: ["CMUX_IOS_FLAG_FEED_TAB": "0"], defaults: defaults(), isDebug: true)
        store.set(.feedTab, enabled: true)
        #expect(!store.isEnabled(.feedTab))
        #expect(store.isPinnedByEnvironment(.feedTab))
    }

    @Test func overrideNotifiesOnceAndResetRestoresDefault() {
        let store = FeatureFlagStore(environment: [:], defaults: defaults(), isDebug: false)
        var changes = 0
        store.onChange = { changes += 1 }
        store.set(.hostsTab, enabled: false)
        store.set(.hostsTab, enabled: false)
        #expect(store.visibleTabs == [.home, .feed, .workspaces, .compose, .search, .cloud, .settings])
        store.reset(.hostsTab)
        #expect(store.isEnabled(.hostsTab))
        #expect(changes == 2)
    }

    @Test func environmentKeysAreScreamingSnakeCase() {
        #expect(ShellFeatureFlag.workspacesTab.environmentKey == "CMUX_IOS_FLAG_WORKSPACES_TAB")
        #expect(ShellFeatureFlag.iPadSidebar.environmentKey == "CMUX_IOS_FLAG_I_PAD_SIDEBAR")
    }
}
