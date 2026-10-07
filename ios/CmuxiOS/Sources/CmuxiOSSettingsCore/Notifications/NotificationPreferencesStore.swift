public import CmuxFeedPushCore
import CmuxiOSFeatureKit
public import Foundation
public import Observation

/// This device's notification preferences: persisted on device and, when
/// lane C7 provides a sink, sent to the push owner after every change.
@MainActor
@Observable
public final class NotificationPreferencesStore {
    public static let defaultsKey = "dev.cmux.ios.next.notifications.v1"

    public private(set) var preferences: NotificationPreferences
    public private(set) var syncState: NotificationSyncState
    /// The send for the latest change; await it to observe its outcome.
    @ObservationIgnored public private(set) var lastSync: Task<Void, Never>?
    @ObservationIgnored private let sink: (any NotificationPreferencesSink)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    @ObservationIgnored private var generation = 0

    public init(sink: (any NotificationPreferencesSink)?, defaults: UserDefaults = .standard,
                key: String = NotificationPreferencesStore.defaultsKey) {
        self.sink = sink
        self.defaults = defaults
        self.key = key
        preferences = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(NotificationPreferences.self, from: $0) } ?? NotificationPreferences()
        syncState = sink == nil ? .localOnly : .synced
    }

    public func update(_ change: (inout NotificationPreferences) -> Void) {
        var next = preferences
        change(&next)
        guard next != preferences else { return }
        preferences = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: key) }
        send(next)
    }

    /// Sends the current value again: a new install (after sign-in) starts
    /// with the owner's defaults until it hears this device's choice.
    public func resend() {
        send(preferences)
    }

    /// Sends the newest value; an older send's result is ignored.
    private func send(_ value: NotificationPreferences) {
        guard let sink else { return }
        generation += 1
        let current = generation
        syncState = .syncing
        lastSync?.cancel()
        lastSync = Task { [weak self] in
            let state: NotificationSyncState
            do {
                switch try await sink.apply(value, key: IntentKey()) {
                case .committed: state = .synced
                case .refused(_, let reason): state = .refused(reason: reason)
                }
            } catch {
                state = .offline
            }
            guard let self, current == self.generation else { return }
            self.syncState = state
        }
    }
}
