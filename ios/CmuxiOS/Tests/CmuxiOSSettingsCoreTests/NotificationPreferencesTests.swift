import CmuxFeedPushCore
import CmuxiOSFeatureKit
import CmuxiOSSettingsCore
import Foundation
import Testing

/// Records what it was sent; answers with a scripted receipt or error.
actor RecordingNotificationSink: NotificationPreferencesSink {
    private(set) var sent: [NotificationPreferences] = []
    var refuse: String?
    var offline = false

    func setOffline(_ value: Bool) { offline = value }
    func setRefuse(_ reason: String?) { refuse = reason }

    func apply(_ preferences: NotificationPreferences, key: IntentKey) async throws -> IntentReceipt {
        if offline { throw FeatureSourceError.offline }
        sent.append(preferences)
        if let refuse { return .refused(key: key, reason: refuse) }
        return .committed(key: key, revision: UInt64(sent.count))
    }
}

@MainActor
@Suite struct NotificationPreferencesTests {
    @Test func everyKindIsOnByDefault() {
        let value = NotificationPreferences()
        for kind in NotificationKind.allCases { #expect(value.isEnabled(kind)) }
        #expect(value.sound && value.timeSensitive)
    }

    @Test func decodingDropsUnknownKinds() throws {
        let json = #"{"enabledKinds":["question","telepathy"],"sound":false}"#
        let value = try JSONDecoder().decode(NotificationPreferences.self, from: Data(json.utf8))
        #expect(value.enabledKinds == [.question])
        #expect(!value.sound)
        #expect(value.timeSensitive)
    }

    @Test func withoutASinkTheValueStaysOnDevice() {
        let suite = TestDefaults()
        let store = NotificationPreferencesStore(sink: nil, defaults: suite.defaults)
        store.update { $0.set(.finished, enabled: false) }
        #expect(store.syncState == .localOnly)
        let reloaded = NotificationPreferencesStore(sink: nil, defaults: suite.defaults)
        #expect(!reloaded.preferences.isEnabled(.finished))
    }

    @Test func changesReachTheSink() async {
        let sink = RecordingNotificationSink()
        let store = NotificationPreferencesStore(sink: sink, defaults: TestDefaults().defaults)
        store.update { $0.set(.terminalAlert, enabled: false) }
        #expect(store.syncState == .syncing)
        await store.lastSync?.value
        #expect(store.syncState == .synced)
        #expect(await sink.sent.last?.isEnabled(.terminalAlert) == false)
    }

    @Test func offlineAndRefusalAreReported() async {
        let sink = RecordingNotificationSink()
        let store = NotificationPreferencesStore(sink: sink, defaults: TestDefaults().defaults)
        await sink.setOffline(true)
        store.update { $0.sound = false }
        await store.lastSync?.value
        #expect(store.syncState == .offline)
        await sink.setOffline(false)
        await sink.setRefuse("Push filter unavailable")
        store.update { $0.sound = true }
        await store.lastSync?.value
        #expect(store.syncState == .refused(reason: "Push filter unavailable"))
    }

    @Test func unchangedValueSendsNothing() async {
        let sink = RecordingNotificationSink()
        let store = NotificationPreferencesStore(sink: sink, defaults: TestDefaults().defaults)
        store.update { $0.sound = true }
        #expect(store.lastSync == nil)
        #expect(await sink.sent.isEmpty)
    }
}
