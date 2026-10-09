import Foundation

/// A browser session that reports `.streaming` at once, one page update,
/// no video, records input and navigations, and ends on `close()`.
public actor MockBrowserStreamSession: BrowserStreamSession {
    public nonisolated let tabID: BrowserTabInfo.ID
    private var state: BrowserStreamState = .streaming(width: 1178, height: 736)
    private var subscribers: [UUID: AsyncStream<BrowserStreamState>.Continuation] = [:]
    private let page: BrowserPageInfo
    public private(set) var inputs: [BrowserInput] = []
    public private(set) var navigations: [BrowserNavigation] = []
    public private(set) var viewports: [BrowserViewport] = []
    public private(set) var pastes: [String] = []

    public init(tabID: BrowserTabInfo.ID, page: BrowserPageInfo = BrowserPageInfo(url: "http://localhost:3000", title: "localhost:3000")) {
        self.tabID = tabID
        self.page = page
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

    public func pageUpdates() async -> AsyncStream<BrowserPageUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: BrowserPageUpdate.self)
        continuation.yield(.pageSize(width: 1440, height: 900))
        continuation.yield(.page(page))
        return stream
    }

    public func videoSamples() async -> AsyncStream<BrowserVideoSample> {
        AsyncStream { _ in }
    }

    public func send(_ input: BrowserInput) async {
        inputs.append(input)
    }

    public func navigate(_ navigation: BrowserNavigation, key: IntentKey) async throws -> IntentReceipt {
        if case .ended = state { throw FeatureSourceError.offline }
        if case .load(let url) = navigation, !["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return .refused(key: key, reason: "scheme")
        }
        navigations.append(navigation)
        return .committed(key: key, revision: UInt64(navigations.count))
    }

    public func setViewport(_ viewport: BrowserViewport) async {
        viewports.append(viewport)
    }

    public func paste(_ text: String) async {
        pastes.append(text)
    }

    public func requestKeyframe() async {}

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
