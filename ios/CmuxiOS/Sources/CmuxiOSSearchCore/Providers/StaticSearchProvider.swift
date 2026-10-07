/// Items compiled into the app (actions, settings pages): one yield, and
/// the stream stays open until cancelled so a session treats it like a live
/// mirror.
public struct StaticSearchProvider: SearchProvider {
    public let entries: [SearchItem]

    public init(_ entries: [SearchItem]) {
        self.entries = entries
    }

    public func items() async -> AsyncStream<[SearchItem]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [SearchItem].self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(entries)
        return stream
    }
}
