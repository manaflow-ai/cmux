import Foundation

/// One implementation per seam, built by the app's composition root for the
/// signed-in account. Feature screens receive only the seams they use.
public struct FeatureSources: Sendable {
    public var feed: any FeedSource
    public var workspaces: any WorkspaceSource
    public var composer: any TaskComposerSink
    public var hosts: any HostsStore
    public var devices: any DeviceRegistry
    public var files: any FileTransfer
    public var browser: any BrowserStreamSource
    /// The mode each seam actually resolved to (a requested `.real` without a
    /// registered implementation resolves to `.mock`).
    public var resolved: [FeatureSeam: FeatureSourceMode]

    public init(
        feed: any FeedSource, workspaces: any WorkspaceSource, composer: any TaskComposerSink,
        hosts: any HostsStore, devices: any DeviceRegistry, files: any FileTransfer,
        browser: any BrowserStreamSource, resolved: [FeatureSeam: FeatureSourceMode]
    ) {
        self.feed = feed
        self.workspaces = workspaces
        self.composer = composer
        self.hosts = hosts
        self.devices = devices
        self.files = files
        self.browser = browser
        self.resolved = resolved
    }

    /// Every seam on its mock.
    public static func mock() -> FeatureSources {
        FeatureSources(
            feed: MockFeedSource(), workspaces: MockWorkspaceSource(), composer: MockTaskComposerSink(),
            hosts: MockHostsStore(), devices: MockDeviceRegistry(), files: MockFileTransfer(),
            browser: MockBrowserStreamSource(),
            resolved: Dictionary(uniqueKeysWithValues: FeatureSeam.allCases.map { ($0, .mock) })
        )
    }
}
