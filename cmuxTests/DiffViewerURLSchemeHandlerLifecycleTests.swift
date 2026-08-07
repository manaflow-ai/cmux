import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct DiffViewerURLSchemeHandlerLifecycleTests {
    @Test(.timeLimit(.minutes(1)))
    func callbacksStayOnMainThreadAndStopNeverWaitsForCallbackDelivery() async throws {
        let token = UUID().uuidString.lowercased()
        let rootURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("index.html", isDirectory: false)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "<!doctype html><title>deadlock regression</title>"
            .write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let handler = CmuxDiffViewerURLSchemeHandler()
        try handler.register(
            token: token,
            files: [.init(requestPath: "/index.html", fileURL: fileURL, mimeType: "text/html")]
        )
        let requestURL = try #require(URL(
            string: "\(CmuxDiffViewerURLSchemeHandler.scheme)://\(token)/index.html"
        ))
        let schemeTask = DiffViewerBlockingMainHopSchemeTask(
            request: URLRequest(url: requestURL)
        )
        var callbackIterator = schemeTask.callbacks.makeAsyncIterator()
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())

        handler.webView(webView, start: schemeTask)
        let firstCallback = try #require(await callbackIterator.next())

        let clock = ContinuousClock()
        let startedAt = clock.now
        handler.webView(webView, stop: schemeTask)
        let stopDuration = startedAt.duration(to: clock.now)

        #expect(firstCallback.wasOnMainThread)
        #expect(stopDuration < .milliseconds(250))
    }
}

/// Models WebKit's synchronous off-main hop to the main run loop without
/// leaving a permanently wedged test process. A callback delivered off-main
/// remains in flight for one second, so a blocking `stop` is deterministic.
private final class DiffViewerBlockingMainHopSchemeTask: NSObject, WKURLSchemeTask {
    struct Callback: Sendable {
        let wasOnMainThread: Bool
    }

    let request: URLRequest
    let callbacks: AsyncStream<Callback>

    private let callbackContinuation: AsyncStream<Callback>.Continuation
    private let simulatedMainHop = DispatchSemaphore(value: 0)

    init(request: URLRequest) {
        self.request = request
        let stream = AsyncStream<Callback>.makeStream()
        callbacks = stream.stream
        callbackContinuation = stream.continuation
    }

    func didReceive(_ response: URLResponse) {
        recordCallback()
    }

    func didReceive(_ data: Data) {
        recordCallback()
    }

    func didFinish() {
        recordCallback()
        callbackContinuation.finish()
    }

    func didFailWithError(_ error: Error) {
        recordCallback()
        callbackContinuation.finish()
    }

    private func recordCallback() {
        let wasOnMainThread = Thread.isMainThread
        callbackContinuation.yield(Callback(wasOnMainThread: wasOnMainThread))
        if !wasOnMainThread {
            _ = simulatedMainHop.wait(timeout: .now() + 1)
        }
    }
}
