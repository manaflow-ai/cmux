import AppKit
import CmuxBrowser
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserViewportRuntimeTests {
    @Test
    func emulatedViewportDrivesDOMDimensionsAndResponsiveMediaQueries() async throws {
        let paneFrame = NSRect(x: 0, y: 0, width: 380, height: 610)
        let window = NSWindow(
            contentRect: paneFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let pane = NSView(frame: paneFrame)
        let webView = CmuxWebView(frame: pane.bounds, configuration: WKWebViewConfiguration())
        let viewportModel = BrowserViewportModel()
        let loadDelegate = BrowserViewportRuntimeLoadDelegate()
        webView.browserViewportModel = viewportModel
        webView.navigationDelegate = loadDelegate
        pane.addSubview(webView)
        window.contentView = pane
        window.orderFrontRegardless()
        defer {
            webView.navigationDelegate = nil
            webView.removeFromSuperview()
            window.close()
        }

        try await loadDelegate.load(
            """
            <!doctype html>
            <html>
              <head>
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <style>
                  #responsive { display: none; }
                  @media (min-width: 1000px) { #responsive { display: block; } }
                </style>
              </head>
              <body><div id="responsive">wide</div></body>
            </html>
            """,
            in: webView
        )

        let viewport = try #require(BrowserViewport(width: 1_280, height: 720))
        viewportModel.setViewport(viewport)
        let layout = try #require(webView.cmuxApplyBrowserViewportLayout(in: pane.bounds))
        #expect(layout.mode == .emulated)

        let rawMetrics = try await webView.callAsyncJavaScript(
            """
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            return {
              width: window.innerWidth,
              height: window.innerHeight,
              wide: window.matchMedia('(min-width: 1000px)').matches,
              responsiveDisplay: getComputedStyle(document.getElementById('responsive')).display
            };
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let metrics = try #require(rawMetrics as? [String: Any])

        #expect(metrics["width"] as? Int == 1_280)
        #expect(metrics["height"] as? Int == 720)
        #expect(metrics["wide"] as? Bool == true)
        #expect(metrics["responsiveDisplay"] as? String == "block")
    }
}
