import CmuxiOSFeatureKit

/// Maps a seam's snapshot stream to search items in a task off the main
/// actor, newest only, so a burst of owner changes costs one mapping.
struct SearchSnapshotMapping<Value: Sendable>: Sendable {
    let transform: @Sendable (Value) -> [SearchItem]

    func stream(_ updates: AsyncStream<SourceSnapshot<Value>>) -> AsyncStream<[SearchItem]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [SearchItem].self, bufferingPolicy: .bufferingNewest(1))
        let transform = transform
        let task = Task {
            for await snapshot in updates {
                continuation.yield(transform(snapshot.value))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
