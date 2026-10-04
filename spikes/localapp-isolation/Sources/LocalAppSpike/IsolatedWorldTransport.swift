import Foundation
import WebKit

/// Design A for WebKit: the acpmux socket and the LocalApp token live in a private content world.
/// The page world receives only a MessagePort (frames in, frames out). The token is handed to the
/// private world at each connect through `callAsyncJavaScript(... contentWorld:)`, which the page
/// world cannot observe, and the endpoint comes only from the host.
@MainActor public final class IsolatedWorldTransport {
    public static let worldName = "cmux-acpmux"
    public let world = WKContentWorld.world(name: worldName)
    private weak var webView: WKWebView?

    public enum Failure: Error { case noWebView }

    /// Call before the web view is created from `configuration`.
    public init(configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(
            WKUserScript(source: SpikeJS.isolatedWorld, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
    }

    public func attach(_ webView: WKWebView) { self.webView = webView }

    /// Opens the socket in the private world (main frame only). Resolves once it is open and the
    /// page has its port. Call again with a fresh token at every reconnect.
    public func connect(endpoint: URL, token: String) async throws {
        guard let webView else { throw Failure.noWebView }
        _ = try await webView.callAsyncJavaScript(
            "return await globalThis.__acpmuxConnect(url, token);",
            arguments: ["url": endpoint.absoluteString, "token": token], in: nil, contentWorld: world)
    }

    /// Runs `body` (a function body) in the private world; for probes.
    public func run(_ body: String) async throws -> Any? {
        guard let webView else { throw Failure.noWebView }
        return try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: world)
    }
}
