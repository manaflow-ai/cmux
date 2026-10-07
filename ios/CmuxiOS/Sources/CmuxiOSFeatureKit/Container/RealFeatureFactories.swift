import Foundation

/// Real implementations registered by feature lanes. A lane fills its slot
/// in the app's composition root (`AppContainer.realFactories`) when its
/// carrier lands; until then the slot is nil and the seam stays on its mock.
public struct RealFeatureFactories: Sendable {
    public var feed: (@Sendable () -> any FeedSource)?
    /// Gets the account's resolved device registry (real or mock), whose
    /// paired Macs are the hosts the workspace list mirrors.
    public var workspaces: (@Sendable (any DeviceRegistry) -> any WorkspaceSource)?
    /// Gets the account's resolved workspace source (real or mock): the
    /// composer targets those hosts and workspaces.
    public var composer: (@Sendable (any WorkspaceSource) -> any TaskComposerSink)?
    public var hosts: (@Sendable () -> any HostsStore)?
    public var devices: (@Sendable () -> any DeviceRegistry)?
    public var files: (@Sendable () -> any FileTransfer)?
    public var browser: (@Sendable () -> any BrowserStreamSource)?
    /// Lane C12: the team's Cloud machines (`CloudDO`).
    public var cloud: (@Sendable () -> any CloudMachineSource)?

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
        case .cloud: cloud != nil
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
        let devices = pick(.devices, devices) { MockDeviceRegistry() as any DeviceRegistry }
        let workspacesFactory = workspaces.map { make in { @Sendable in make(devices) } }
        let workspaces = pick(.workspaces, workspacesFactory) { MockWorkspaceSource() as any WorkspaceSource }
        let composerFactory = composer.map { make in { @Sendable in make(workspaces) } }
        let composer = pick(.composer, composerFactory) { MockTaskComposerSink() as any TaskComposerSink }
        let hosts = pick(.hosts, hosts) { MockHostsStore() as any HostsStore }
        let files = pick(.files, files) { MockFileTransfer() as any FileTransfer }
        let browser = pick(.browser, browser) { MockBrowserStreamSource() as any BrowserStreamSource }
        let cloud = pick(.cloud, cloud) { MockCloudMachineSource() as any CloudMachineSource }
        return FeatureSources(feed: feed, workspaces: workspaces, composer: composer, hosts: hosts,
                              devices: devices, files: files, browser: browser, cloud: cloud, resolved: resolved)
    }
}
