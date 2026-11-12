import AppKit
import CmuxBrowser
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct BrowserDesignModeSmoothScrollingTests {
    @MainActor
    @Test func smoothScrollingPageCapturesRequestedRegionAndRestoresOffset() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let renderHost = BrowserOffscreenRenderHost(
            webView: webView,
            viewportSize: webView.bounds.size
        )
        defer { renderHost.restore() }
        let (loaded, loadedContinuation) = AsyncStream<Void>.makeStream()
        let navigationDelegate = BrowserDesignModeTestNavigationDelegate {
            loadedContinuation.yield()
            loadedContinuation.finish()
        }
        defer { withExtendedLifetime(navigationDelegate) {} }
        webView.navigationDelegate = navigationDelegate
        webView.loadHTMLString(
            """
            <style>
              html { scroll-behavior: smooth; }
              html, body { margin: 0; width: 640px; height: 2000px; }
              .top { height: 1000px; background: red; }
              .bottom { height: 1000px; background: blue; }
            </style>
            <div class="top"></div>
            <div class="bottom"></div>
            """,
            baseURL: nil
        )
        let didLoad = await BrowserDesignModeScreenshotEvaluatorTests.awaitPageLoad(loaded)
        #expect(didLoad, "WebKit never finished loading the test page")
        guard didLoad else { return }

        let image = try await BrowserScreenshotWebViewSnapshotter.captureDocumentRect(
            NSRect(x: 0, y: 1_500, width: 640, height: 100),
            from: webView
        )
        let tiffData = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiffData))
        let sampledColor = bitmap.colorAt(
            x: Int(image.size.width / 2),
            y: Int(image.size.height / 2)
        )
        let color = try #require(sampledColor?.usingColorSpace(.deviceRGB))
        let restoredOffset = try #require(
            try await webView.evaluateJavaScript("window.scrollY") as? Double
        )

        #expect(color.blueComponent > 0.9)
        #expect(color.redComponent < 0.1)
        #expect(abs(restoredOffset) < 1)
    }
}
