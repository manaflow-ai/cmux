import Foundation

extension FeatureSources {
    /// DEV previews: sets the connection of every seam that is on a mock
    /// owner (feed, workspaces, composer, hosts, devices). Real seams are
    /// left alone.
    public func setMockConnection(_ connection: SourceConnection) async {
        await (feed as? MockFeedSource)?.hub.setConnection(connection)
        await (workspaces as? MockWorkspaceSource)?.hub.setConnection(connection)
        await (composer as? MockTaskComposerSink)?.hub.setConnection(connection)
        await (hosts as? MockHostsStore)?.hub.setConnection(connection)
        await (devices as? MockDeviceRegistry)?.hub.setConnection(connection)
    }
}
