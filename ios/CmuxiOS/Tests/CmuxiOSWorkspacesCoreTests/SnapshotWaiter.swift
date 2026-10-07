import CmuxiOSFeatureKit
import Foundation

/// Reads a source's stream until a snapshot satisfies a predicate. No
/// clocks: the test only waits for the source to publish.
struct SnapshotWaiter {
    var iterator: AsyncStream<SourceSnapshot<[HostWorkspaces]>>.AsyncIterator

    init(_ stream: AsyncStream<SourceSnapshot<[HostWorkspaces]>>) {
        iterator = stream.makeAsyncIterator()
    }

    mutating func until(_ predicate: (SourceSnapshot<[HostWorkspaces]>) -> Bool) async -> SourceSnapshot<[HostWorkspaces]>? {
        while let snapshot = await iterator.next() {
            if predicate(snapshot) { return snapshot }
        }
        return nil
    }
}
