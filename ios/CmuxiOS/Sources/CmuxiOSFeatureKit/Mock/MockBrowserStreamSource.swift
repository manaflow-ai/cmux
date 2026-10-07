import Foundation

/// A `BrowserStreamSource` over sample tabs on the sample Mac Studio.
/// Sessions stream a placeholder track id; no video is produced.
public final class MockBrowserStreamSource: BrowserStreamSource {
    public init() {}

    public func tabs(on hostID: HostID) async -> AsyncStream<SourceSnapshot<[BrowserTabInfo]>> {
        let snapshot = SourceSnapshot(revision: 1, value: MockFixtures.browserTabs(on: hostID), connection: .live(path: "mock"))
        return AsyncStream { continuation in
            continuation.yield(snapshot)
        }
    }

    public func open(_ tabID: BrowserTabInfo.ID, on hostID: HostID) async throws -> any BrowserStreamSession {
        guard MockFixtures.browserTabs(on: hostID).contains(where: { $0.id == tabID }) else {
            throw FeatureSourceError.notFound(tabID)
        }
        return MockBrowserStreamSession(tabID: tabID)
    }
}
