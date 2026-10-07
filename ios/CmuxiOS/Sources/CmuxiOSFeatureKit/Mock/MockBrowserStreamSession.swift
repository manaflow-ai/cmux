import Foundation

/// A browser session that reports `.streaming` at once, records input and
/// navigations, and ends on `close()`.
public actor MockBrowserStreamSession: BrowserStreamSession {
    public nonisolated let tabID: BrowserTabInfo.ID
    private var state: BrowserStreamState = .streaming(videoTrackID: "mock-video", width: 1280, height: 800)
    private var subscribers: [UUID: AsyncStream<BrowserStreamState>.Continuation] = [:]
    public private(set) var inputs: [BrowserInput] = []
    public private(set) var navigations: [BrowserNavigation] = []

    public init(tabID: BrowserTabInfo.ID) {
        self.tabID = tabID
    }

    public func states() async -> AsyncStream<BrowserStreamState> {
        let (stream, continuation) = AsyncStream.makeStream(of: BrowserStreamState.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(state)
        if case .ended = state {
            continuation.finish()
            return stream
        }
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        return stream
    }

    public func send(_ input: BrowserInput) async {
        inputs.append(input)
    }

    public func navigate(_ navigation: BrowserNavigation, key: IntentKey) async throws -> IntentReceipt {
        if case .ended = state { throw FeatureSourceError.offline }
        navigations.append(navigation)
        return .committed(key: key, revision: UInt64(navigations.count))
    }

    public func close() async {
        state = .ended(reason: nil)
        for continuation in subscribers.values {
            continuation.yield(state)
            continuation.finish()
        }
        subscribers.removeAll()
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }
}
