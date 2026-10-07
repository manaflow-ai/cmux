public import CmuxiOSFeatureKit
public import CmuxLink

/// Fixed badges for the mock Macs: the Mac Studio direct at 12 ms, the Mac
/// mini over the relay at 140 ms, yielded once.
public struct MockLinkDiagnosticsSource: LinkDiagnosticsSource {
    public var badges: [DeviceRecord.ID: PathBadge]

    public init(badges: [DeviceRecord.ID: PathBadge] = MockLinkDiagnosticsSource.fixtureBadges) {
        self.badges = badges
    }

    public static let fixtureBadges: [DeviceRecord.ID: PathBadge] = [
        MockFixtures.studio.rawValue: PathBadge(path: LinkPath(kind: .direct, carrier: .direct), rtt: .milliseconds(12)),
        MockFixtures.mini.rawValue: PathBadge(path: LinkPath(kind: .relay, carrier: .doRelay), rtt: .milliseconds(140)),
    ]

    public func updates() async -> AsyncStream<[DeviceRecord.ID: PathBadge]> {
        let badges = badges
        return AsyncStream { $0.yield(badges) }
    }
}
