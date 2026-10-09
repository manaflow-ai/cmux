import CmuxiOSPlatform
import CmuxiOSShell
import Foundation
import Testing

@MainActor
@Suite struct FeatureFlagRemoteLayerTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "c16.flags." + UUID().uuidString)!
    }

    @Test func remoteShowsATabInReleaseAndNotifiesOnce() {
        let store = FeatureFlagStore(environment: [:], defaults: defaults(), isDebug: false)
        var changes = 0
        store.onChange = { changes += 1 }
        store.applyRemote(RemoteConfig(flags: ["feedTab": .bool(true), "unknownFlag": .bool(true)]))
        store.applyRemote(RemoteConfig(flags: ["feedTab": .bool(true)]))
        #expect(store.visibleTabs == [.home, .feed, .settings])
        #expect(store.layer(.feedTab) == .remote)
        #expect(changes == 1)
    }

    @Test func deviceOverrideAndEnvironmentBeatRemote() {
        let store = FeatureFlagStore(environment: ["CMUX_IOS_FLAG_HOSTS_TAB": "0"], defaults: defaults(), isDebug: false)
        store.set(.feedTab, enabled: false)
        store.applyRemote(RemoteConfig(flags: ["feedTab": .bool(true), "hostsTab": .bool(true)]))
        #expect(!store.isEnabled(.feedTab))
        #expect(store.layer(.feedTab) == .deviceOverride)
        #expect(!store.isEnabled(.hostsTab))
        #expect(store.layer(.hostsTab) == .environment)
    }

    @Test func clearingRemoteRestoresBuildDefault() {
        let store = FeatureFlagStore(environment: [:], defaults: defaults(), isDebug: false)
        store.applyRemote(RemoteConfig(flags: ["composeTab": .bool(true)]))
        store.applyRemote(.empty)
        #expect(store.isEnabled(.composeTab))
        #expect(store.layer(.composeTab) == .buildDefault)
    }
}
