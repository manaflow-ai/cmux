import AppKit
import Foundation
@testable import LocalAppSpike
import WebKit

/// One page of the bench in one transport mode.
@MainActor final class BenchPage: NSObject, WKNavigationDelegate {
    enum Mode: String, CaseIterable {
        case direct          // today: page world owns socket and token
        case isolated        // design A
        case relay           // design B, coalesced inbound
        case relayPerFrame = "relay-perframe" // design B, one evaluateJavaScript per frame
    }

    static let pageOrigin = "http://localhost"
    static let relayOrigin = "cmux-agent://pane"

    let mode: Mode
    let webView: WKWebView
    let window: NSWindow
    let isolated: IsolatedWorldTransport?
    let relay: NativeRelayTransport?
    private(set) var suppressionOff = false
    /// LOCALAPP_SPIKE_VISIBLE=1 (a live Mac with a window server): the window is put on screen,
    /// without activating the app, so WebKit treats the page as visible like the real pane.
    static let visible = ProcessInfo.processInfo.environment["LOCALAPP_SPIKE_VISIBLE"] == "1"
    private static var placed = 0
    private var loaded: CheckedContinuation<Void, Never>?

    init(mode: Mode, spy: Bool) {
        self.mode = mode
        let configuration = WKWebViewConfiguration()
        let controller = configuration.userContentController
        if spy {
            controller.addUserScript(WKUserScript(source: SpikeJS.pageSpy, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        controller.addUserScript(WKUserScript(source: SpikeJS.benchPage, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        isolated = mode == .isolated ? IsolatedWorldTransport(configuration: configuration) : nil
        relay = switch mode {
        case .relay: NativeRelayTransport(configuration: configuration, delivery: .coalesced)
        case .relayPerFrame: NativeRelayTransport(configuration: configuration, delivery: .perFrame)
        default: nil
        }
        // The real pane is on screen; the bench window is not. Turn off WebKit's hidden-page
        // throttling where the SPI exists, so the bench does not measure background suppression.
        let preferences = configuration.preferences
        for key in ["pageVisibilityBasedProcessSuppressionEnabled", "hiddenPageDOMTimerThrottlingEnabled"]
        where preferences.responds(to: NSSelectorFromString("_set\(key.prefix(1).uppercased())\(key.dropFirst()):")) {
            preferences.setValue(false, forKey: key)
            suppressionOff = true
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        webView = WKWebView(frame: window.contentView?.bounds ?? .zero, configuration: configuration)
        super.init()
        window.contentView?.addSubview(webView)
        webView.navigationDelegate = self
        isolated?.attach(webView)
        relay?.attach(webView)
        if Self.visible {
            NSApplication.shared.setActivationPolicy(.accessory)
            window.setFrameOrigin(NSPoint(x: 40 + 30 * Self.placed, y: 40 + 30 * Self.placed))
            Self.placed += 1
            window.orderFrontRegardless()
        }
    }

    func load() async {
        await withCheckedContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString("<!doctype html><html><body>bench</body></html>", baseURL: URL(string: Self.pageOrigin + "/"))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    @discardableResult
    func page(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
    }

    /// Connects this page's transport; the daemon sees `initialize` with the token in every mode.
    func connect(_ url: URL, token: String) async throws {
        switch mode {
        case .direct:
            try await page("return await startDirect(url, token);", ["url": url.absoluteString, "token": token])
        case .isolated:
            try await page("window.__pending = startIsolated(); return true;")
            try await isolated!.connect(endpoint: url, token: token)
            try await page("return await window.__pending;")
        case .relay, .relayPerFrame:
            try await relay!.connect(endpoint: url, token: token, origin: Self.relayOrigin)
            try await page(
                "return await startRelay(mode, (t) => window.webkit.messageHandlers.\(NativeRelayTransport.handlerName).postMessage(t));",
                ["mode": mode.rawValue])
        }
    }

    func close() {
        relay?.close()
        webView.removeFromSuperview()
        window.close()
    }
}
