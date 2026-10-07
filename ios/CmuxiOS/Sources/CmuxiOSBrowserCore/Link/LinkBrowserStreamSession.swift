import CmuxBrowserStream
public import CmuxiOSFeatureKit
import Foundation

/// A `BrowserStreamSession` over one `BrowserStreamClient`: fans the
/// client's single event stream out to states and page updates, maps video
/// frames to samples and FeatureKit input and navigation to `cmux.rb/1`.
public actor LinkBrowserStreamSession: BrowserStreamSession {
    public nonisolated let tabID: BrowserTabInfo.ID
    private let client: BrowserStreamClient
    private var state: BrowserStreamState
    private var size: (width: Int, height: Int)
    private var stateSubscribers: [UUID: AsyncStream<BrowserStreamState>.Continuation] = [:]
    /// Newest value per kind (E1): a consumer that stops reading holds at most five.
    private let pages = BrowserPageUpdateBuffer()
    private var pump: Task<Void, Never>?

    init(tabID: BrowserTabInfo.ID, client: BrowserStreamClient, opened: BrowserChannelOpened) {
        self.tabID = tabID
        self.client = client
        size = (Int(opened.width), Int(opened.height))
        state = .streaming(width: size.width, height: size.height)
        pages.push(.pageSize(width: opened.pageWidth, height: opened.pageHeight))
    }

    /// Starts relaying the client's events; called once after init.
    func start() {
        guard pump == nil else { return }
        let events = client.events
        pump = Task { [weak self] in
            for await event in events {
                await self?.relay(event)
            }
            await self?.ended(reason: nil)
        }
    }

    public func states() -> AsyncStream<BrowserStreamState> {
        let (stream, continuation) = AsyncStream.makeStream(of: BrowserStreamState.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(state)
        if case .ended = state {
            continuation.finish()
            return stream
        }
        let id = UUID()
        stateSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        return stream
    }

    public func pageUpdates() -> AsyncStream<BrowserPageUpdate> {
        pages.stream
    }

    public func videoSamples() -> AsyncStream<BrowserVideoSample> {
        let frames = client.frames
        return AsyncStream(bufferingPolicy: .bufferingNewest(30)) { continuation in
            let task = Task {
                for await frame in frames {
                    continuation.yield(BrowserVideoSample(
                        frame: frame.frame, refFrame: frame.isKeyframe ? nil : frame.refFrame, isKeyframe: frame.isKeyframe,
                        codec: frame.codec.rawValue, accessUnit: frame.accessUnit, captureMicros: frame.captureMicros))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func send(_ input: BrowserInput) async {
        try? await client.send(input.rbEvent)
    }

    public func navigate(_ navigation: BrowserNavigation, key: IntentKey) async throws -> IntentReceipt {
        do {
            switch navigation {
            case .load(let url):
                if let refusal = try await client.navigate(to: url) {
                    return .refused(key: key, reason: refusal.rawValue)
                }
            case .back: try await client.history(.back)
            case .forward: try await client.history(.forward)
            case .reload: try await client.history(.reload)
            case .stop: try await client.history(.stop)
            }
            return .committed(key: key, revision: 0)
        } catch {
            throw FeatureSourceError.offline
        }
    }

    public func setViewport(_ viewport: BrowserViewport) async {
        let screen = RbScreenInfo(cssWidth: UInt32(max(1, viewport.width)), cssHeight: UInt32(max(1, viewport.height)),
                                  scale: viewport.scale * Double(max(1, viewport.zoomBucket)),
                                  refreshHz: UInt32(max(1, viewport.refreshHz)))
        try? await client.setScreen(screen)
    }

    public func paste(_ text: String) async {
        try? await client.pushClipboard(text)
    }

    public func requestKeyframe() async {
        await client.requestRecovery()
    }

    public func close() async {
        await client.close()
        ended(reason: nil)
    }

    // MARK: Relay

    private func relay(_ event: BrowserStreamEvent) {
        switch event {
        case .page(let page):
            pages.push(.page(BrowserPageInfo(url: page.url, title: page.title, isLoading: page.loading,
                                                          canGoBack: page.canGoBack, canGoForward: page.canGoForward)))
        case .cursor(let cursor):
            pages.push(.cursor(cursor.kind))
        case .textInput(let type, _):
            pages.push(.textFocus(type != "none"))
        case .clipboardWrite(let items):
            if let text = items.compactMap(\.plainText).first { pages.push(.clipboard(text)) }
        case .screenApplied(let width, let height):
            size = (Int(width), Int(height))
            publish(.streaming(width: size.width, height: size.height))
        case .state(.paused):
            publish(.paused)
        case .state(.live):
            if case .paused = state { publish(.streaming(width: size.width, height: size.height)) }
        case .closed(let reason):
            ended(reason: reason == "local" ? nil : reason)
        default:
            break
        }
    }

    private func publish(_ next: BrowserStreamState) {
        guard state != next else { return }
        if case .ended = state { return }
        state = next
        for continuation in stateSubscribers.values { continuation.yield(next) }
    }

    private func ended(reason: String?) {
        if case .ended = state { return }
        state = .ended(reason: reason)
        for continuation in stateSubscribers.values {
            continuation.yield(state)
            continuation.finish()
        }
        stateSubscribers.removeAll()
        pages.finish()
    }

    private func unsubscribe(_ id: UUID) {
        stateSubscribers[id] = nil
    }
}
