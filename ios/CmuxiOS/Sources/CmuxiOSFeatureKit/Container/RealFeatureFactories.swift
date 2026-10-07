import Foundation

/// Real implementations registered by feature lanes. A lane fills its slot
/// in the app's composition root (`AppContainer.realFactories`) when its
/// carrier lands; until then the slot is nil and the seam stays on its mock.
public struct RealFeatureFactories: Sendable {
    public var feed: (@Sendable () -> any FeedSource)?
    public var workspaces: (@Sendable () -> any WorkspaceSource)?
    public var composer: (@Sendable () -> any TaskComposerSink)?
    public var hosts: (@Sendable () -> any HostsStore)?
    public var devices: (@Sendable () -> any DeviceRegistry)?
    public var files: (@Sendable () -> any FileTransfer)?
    public var browser: (@Sendable () -> any BrowserStreamSource)?

    public init() {}

    public func isRegistered(_ seam: FeatureSeam) -> Bool {
        switch seam {
        case .feed: feed != nil
        case .workspaces: workspaces != nil
        case .composer: composer != nil
        case .hosts: hosts != nil
        case .devices: devices != nil
        case .files: files != nil
        case .browser: browser != nil
        }
    }

    /// Builds the sources for the requested modes. Each seam uses its real
    /// factory when `.real` is requested and registered, else its mock.
    public func resolve(_ modes: [FeatureSeam: FeatureSourceMode]) -> FeatureSources {
        var resolved: [FeatureSeam: FeatureSourceMode] = [:]
        func pick<Source>(_ seam: FeatureSeam, _ real: (@Sendable () -> Source)?, mock: () -> Source) -> Source {
            if modes[seam] == .real, let real {
                resolved[seam] = .real
                return real()
            }
            resolved[seam] = .mock
            return mock()
        }
        let feed = pick(.feed, feed) { MockFeedSource() as any FeedSource }
        let workspaces = pick(.workspaces, workspaces) { MockWorkspaceSource() as any WorkspaceSource }
        let composer = pick(.composer, composer) { MockTaskComposerSink() as any TaskComposerSink }
        let hosts = pick(.hosts, hosts) { MockHostsStore() as any HostsStore }
        let devices = pick(.devices, devices) { MockDeviceRegistry() as any DeviceRegistry }
        let files = pick(.files, files) { MockFileTransfer() as any FileTransfer }
        let browser = pick(.browser, browser) { MockBrowserStreamSource() as any BrowserStreamSource }
        return FeatureSources(feed: feed, workspaces: workspaces, composer: composer, hosts: hosts,
                              devices: devices, files: files, browser: browser, resolved: resolved)
    }
}
