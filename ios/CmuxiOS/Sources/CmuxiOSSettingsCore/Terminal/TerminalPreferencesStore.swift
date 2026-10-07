public import CmuxTerminalRenderCore
public import Foundation
public import Observation

/// The one owner of this device's terminal settings: persists them in
/// `UserDefaults` and feeds every terminal surface (`TerminalAppearanceProviding`).
@MainActor
@Observable
public final class TerminalPreferencesStore: TerminalAppearanceProviding {
    public static let defaultsKey = "dev.cmux.ios.next.terminal.v1"

    public private(set) var preferences: TerminalPreferences
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<TerminalAppearance>.Continuation] = [:]

    public init(defaults: UserDefaults = .standard, key: String = TerminalPreferencesStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
        preferences = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(TerminalPreferences.self, from: $0) } ?? TerminalPreferences()
    }

    public var appearance: TerminalAppearance { preferences.appearance }

    /// Changes, normalizes, persists and publishes the settings.
    public func update(_ change: (inout TerminalPreferences) -> Void) {
        var next = preferences
        change(&next)
        next = next.normalized()
        guard next != preferences else { return }
        let appearanceChanged = next.appearance != preferences.appearance
        preferences = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: key) }
        if appearanceChanged {
            let value = next.appearance
            for continuation in subscribers.values { continuation.yield(value) }
        }
    }

    /// Back to the defaults (the stored value is removed).
    public func reset() {
        update { $0 = TerminalPreferences() }
        defaults.removeObject(forKey: key)
    }

    public func appearanceUpdates() -> AsyncStream<TerminalAppearance> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<TerminalAppearance>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(appearance)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[id] = nil }
        }
        return stream
    }

    public var subscriberCount: Int { subscribers.count }
}
