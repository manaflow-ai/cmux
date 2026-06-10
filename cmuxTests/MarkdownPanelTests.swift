import AppKit
import Combine
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class MarkdownPanelTests: XCTestCase {
    func renderMarkdown(_ markdown: String, in webView: WKWebView) async throws {
        let data = try JSONSerialization.data(withJSONObject: [markdown])
        let literal = try XCTUnwrap(String(data: data, encoding: .utf8))
        _ = try await webView.evaluateJavaScript("window.__cmuxRenderMarkdown(\(literal)[0]);")
    }

}

final class MarkdownShellLoadDelegate: NSObject, WKNavigationDelegate {
    let expectation: XCTestExpectation
    var error: Error?

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        expectation.fulfill()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error
        expectation.fulfill()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
        expectation.fulfill()
    }
}

final class MarkdownURLSchemeTaskSpy: NSObject, WKURLSchemeTask {
    struct Snapshot {
        let responses: [URLResponse]
        let data: Data
        let didFinish: Bool
        let error: Error?
    }

    let request: URLRequest
    private let finishedExpectation: XCTestExpectation
    private let lock = NSLock()
    private var responses: [URLResponse] = []
    private var receivedData = Data()
    private var finished = false
    private var receivedError: Error?

    init(request: URLRequest, finishedExpectation: XCTestExpectation) {
        self.request = request
        self.finishedExpectation = finishedExpectation
    }

    func didReceive(_ response: URLResponse) {
        lock.lock()
        responses.append(response)
        lock.unlock()
    }

    func didReceive(_ data: Data) {
        lock.lock()
        receivedData.append(data)
        lock.unlock()
    }

    func didFinish() {
        lock.lock()
        finished = true
        lock.unlock()
        finishedExpectation.fulfill()
    }

    func didFailWithError(_ error: Error) {
        lock.lock()
        receivedError = error
        lock.unlock()
        finishedExpectation.fulfill()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            responses: responses,
            data: receivedData,
            didFinish: finished,
            error: receivedError
        )
    }
}

final class MarkdownRemoteImageHoldingSchemeHandler: NSObject, WKURLSchemeHandler {
    private var tasks: [ObjectIdentifier: WKURLSchemeTask] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        tasks[ObjectIdentifier(urlSchemeTask as AnyObject)] = urlSchemeTask
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        tasks[ObjectIdentifier(urlSchemeTask as AnyObject)] = nil
    }

    func cancelOpenTasks() {
        let openTasks = Array(tasks.values)
        tasks.removeAll()
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        for task in openTasks {
            task.didFailWithError(error)
        }
    }
}
