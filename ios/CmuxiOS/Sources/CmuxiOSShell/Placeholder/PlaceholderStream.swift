public import CmuxiOSFeatureKit
import Foundation

/// Maps a seam's snapshot stream to placeholder snapshots. The upstream is
/// subscribed only while the returned stream is iterated (the screen is
/// visible), so a hidden tab costs nothing.
public enum PlaceholderStream {
    public typealias Factory = @Sendable () async -> AsyncStream<PlaceholderSnapshot>

    public static func map<Value: Sendable>(
        isMock: Bool,
        _ upstream: @escaping @Sendable () async -> AsyncStream<SourceSnapshot<Value>>,
        sections: @escaping @Sendable (Value) -> [PlaceholderSection]
    ) -> Factory {
        {
            AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let task = Task {
                    for await snapshot in await upstream() {
                        continuation.yield(PlaceholderSnapshot(
                            connection: snapshot.connection, isMock: isMock, sections: sections(snapshot.value)))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}
