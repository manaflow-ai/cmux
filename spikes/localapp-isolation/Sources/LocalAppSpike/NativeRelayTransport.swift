import Darwin
import Foundation
import os
import WebKit

/// Main-thread cost of the relay, for the bench.
public struct RelayStats: Sendable {
    public var inboundFrames = 0
    public var flushes = 0
    public var outboundFrames = 0
    /// Wall and thread-CPU nanoseconds spent on the main thread in the relay's own callbacks.
    public var mainWallNanos: UInt64 = 0
    public var mainCPUNanos: UInt64 = 0
    public var longestMainCallNanos: UInt64 = 0
    /// Socket receive (delegate queue) to the start of the main-thread flush that delivered it.
    public var queueDelayNanos: [UInt64] = []
}

/// Design B for WebKit: Swift owns the acpmux socket, puts the token in the first frame, and relays
/// frames. Inbound frames are coalesced: every frame that arrived before the main thread got to the
/// flush goes in ONE `evaluateJavaScript` call (`perFrame` turns that off, for comparison).
/// Outbound frames come through a `WKScriptMessageHandler` in the page world (main frame only).
@MainActor public final class NativeRelayTransport: NSObject, WKScriptMessageHandler {
    public static let handlerName = "acpmuxRelay"
    public enum Delivery: Sendable { case coalesced, perFrame }
    /// Most frames in one flush, so the first frame of a long burst is not held behind the rest.
    public static let maximumBatch = 64

    private let delivery: Delivery
    private weak var webView: WKWebView?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var token: String?
    private var firstOutbound = true
    private let inbox = OSAllocatedUnfairLock(initialState: Inbox())
    public private(set) var stats = RelayStats()

    struct Inbox {
        var frames: [String] = []
        var arrivals: [UInt64] = []
        var scheduled = false
    }

    public enum Failure: Error { case closed, badFirstFrame }

    public init(configuration: WKWebViewConfiguration, delivery: Delivery = .coalesced) {
        self.delivery = delivery
        super.init()
        configuration.userContentController.add(Weak(self), contentWorld: .page, name: Self.handlerName)
    }

    public func attach(_ webView: WKWebView) { self.webView = webView }

    public func resetStats() { stats = RelayStats() }

    /// Opens the socket with the page's Origin and resolves once it is open.
    public func connect(endpoint: URL, token: String, origin: String) async throws {
        self.token = token
        firstOutbound = true
        var request = URLRequest(url: endpoint)
        request.setValue(origin, forHTTPHeaderField: "Origin")
        let opened = OpenWaiter()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        let session = URLSession(configuration: .ephemeral, delegate: opened, delegateQueue: queue)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            opened.continuation = continuation
            task.resume()
        }
        receive(task)
    }

    nonisolated private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, case .success(let message) = result else { return }
            let text: String
            switch message {
            case .string(let string): text = string
            case .data(let data): text = String(decoding: data, as: UTF8.self)
            @unknown default: return
            }
            self.arrived(text)
            self.receive(task)
        }
    }

    /// On the session's delegate queue.
    nonisolated private func arrived(_ text: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        if delivery == .perFrame {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.deliver([text], firstArrival: now) } }
            return
        }
        let schedule = inbox.withLock { box -> Bool in
            box.frames.append(text)
            box.arrivals.append(now)
            if box.scheduled { return false }
            box.scheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.flush()
            }
        }
    }

    /// Delivers up to ``maximumBatch`` frames; schedules another flush for the rest.
    private func flush() {
        let limit = Self.maximumBatch
        let (frames, first, more) = inbox.withLock { box -> ([String], UInt64, Bool) in
            let count = min(limit, box.frames.count)
            let taken = Array(box.frames.prefix(count))
            let first = box.arrivals.first ?? 0
            box.frames.removeFirst(count)
            box.arrivals.removeFirst(count)
            box.scheduled = !box.frames.isEmpty
            return (taken, first, box.scheduled)
        }
        deliver(frames, firstArrival: first)
        if more { DispatchQueue.main.async { MainActor.assumeIsolated { self.flush() } } }
    }

    private func deliver(_ frames: [String], firstArrival: UInt64) {
        guard !frames.isEmpty, let webView else { return }
        let wall0 = DispatchTime.now().uptimeNanoseconds
        let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        stats.queueDelayNanos.append(wall0 &- firstArrival)
        // JSON is a subset of JavaScript: an array of string literals.
        let json = (try? JSONSerialization.data(withJSONObject: frames)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        webView.evaluateJavaScript("__relayRecv(\(json))", completionHandler: nil)
        stats.inboundFrames += frames.count
        stats.flushes += 1
        account(wall0: wall0, cpu0: cpu0)
    }

    private func account(wall0: UInt64, cpu0: UInt64) {
        let wall = DispatchTime.now().uptimeNanoseconds &- wall0
        stats.mainWallNanos &+= wall
        stats.mainCPUNanos &+= clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- cpu0
        stats.longestMainCallNanos = max(stats.longestMainCallNanos, wall)
    }

    // MARK: Outbound

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let wall0 = DispatchTime.now().uptimeNanoseconds
        let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        defer { account(wall0: wall0, cpu0: cpu0) }
        guard message.webView === webView, message.frameInfo.isMainFrame, let task, var text = message.body as? String else { return }
        if firstOutbound {
            firstOutbound = false
            guard let withToken = Self.addToken(token, to: text) else {
                task.cancel(with: .policyViolation, reason: nil)
                return
            }
            token = nil
            text = withToken
        }
        stats.outboundFrames += 1
        task.send(.string(text)) { _ in }
    }

    /// The page's first frame with `params._meta.acpmux.localAppToken`; nil unless it is `initialize`.
    nonisolated static func addToken(_ token: String?, to text: String) -> String? {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              object["method"] as? String == "initialize"
        else { return nil }
        guard let token else { return text }
        var params = object["params"] as? [String: Any] ?? [:]
        var meta = params["_meta"] as? [String: Any] ?? [:]
        var acpmux = meta["acpmux"] as? [String: Any] ?? [:]
        acpmux["localAppToken"] = token
        meta["acpmux"] = acpmux
        params["_meta"] = meta
        object["params"] = params
        return (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) }
    }

    public func close() {
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }
}

private final class OpenWaiter: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var continuation: CheckedContinuation<Void, Error>?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol subprotocol: String?) {
        continuation?.resume()
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        continuation?.resume(throwing: error ?? NativeRelayTransport.Failure.closed)
        continuation = nil
    }
}

/// The user content controller retains its handlers.
private final class Weak: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
