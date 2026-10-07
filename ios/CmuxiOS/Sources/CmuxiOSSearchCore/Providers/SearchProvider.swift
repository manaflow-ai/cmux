/// A read-only view of one owner's mirror as search items. The stream
/// yields the current items first, then once per owner snapshot (newest
/// only); cancelling the iteration ends the owner subscription.
public protocol SearchProvider: Sendable {
    func items() async -> AsyncStream<[SearchItem]>
}
