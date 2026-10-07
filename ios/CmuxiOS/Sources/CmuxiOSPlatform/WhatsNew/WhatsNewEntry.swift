import Foundation

/// The notes for one app version.
public struct WhatsNewEntry: Hashable, Sendable, Identifiable {
    public var id: String { version.description }
    public let version: AppVersion
    public let items: [WhatsNewItem]
    /// Channels that may show the page; nil means the team channels (dev and
    /// beta). The App Store app sees a page only when it lists `.appStore`,
    /// because App Review rejected beta-announcement surfaces (2.2).
    public let channels: Set<BuildChannel>?

    public init(version: AppVersion, items: [WhatsNewItem], channels: Set<BuildChannel>? = nil) {
        self.version = version
        self.items = items
        self.channels = channels
    }

    public func isVisible(on channel: BuildChannel) -> Bool {
        (channels ?? [.dev, .beta]).contains(channel)
    }
}
