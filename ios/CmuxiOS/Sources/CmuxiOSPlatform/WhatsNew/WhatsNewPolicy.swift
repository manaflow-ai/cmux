public import Foundation

/// When What's New shows (c16-platform.md section 7): once after an update
/// that has a visible entry newer than the last version the user saw, never
/// on first install. The last seen version is client view state.
public struct WhatsNewPolicy: @unchecked Sendable {
    public static let lastSeenKey = "cmux.ios.whatsNew.lastSeenVersion"
    public let channel: BuildChannel
    // UserDefaults is documented thread-safe.
    private let defaults: UserDefaults

    public init(channel: BuildChannel, defaults: UserDefaults = .standard) {
        self.channel = channel
        self.defaults = defaults
    }

    /// Visible entries, newest first (the Settings archive).
    public func visibleEntries(_ entries: [WhatsNewEntry]) -> [WhatsNewEntry] {
        entries.filter { $0.isVisible(on: channel) }.sorted { $0.version > $1.version }
    }

    /// The entry to show at launch, recording `current` as seen. Nil on first
    /// install, when nothing newer is visible, or when already seen.
    public func entryToPresent(_ entries: [WhatsNewEntry], current: AppVersion) -> WhatsNewEntry? {
        let lastSeen = defaults.string(forKey: Self.lastSeenKey).flatMap(AppVersion.init)
        if lastSeen.map({ $0 < current }) ?? true {
            defaults.set(current.description, forKey: Self.lastSeenKey)
        }
        guard let lastSeen else { return nil }
        return visibleEntries(entries).first { $0.version > lastSeen && $0.version <= current }
    }
}
