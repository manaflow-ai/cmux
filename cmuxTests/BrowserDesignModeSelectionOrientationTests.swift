import AppKit
import CmuxBrowser
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// #18793: a Design Mode selection of a static element keeps its top at the top. The element is
/// red above blue; the capture's top rows must be red and its bottom rows blue, for a selection
/// inside one viewport and for one stitched from several.
@Suite
struct BrowserDesignModeSelectionOrientationTests {
    @MainActor
    @Test(arguments: [
        NSRect(x: 0, y: 300, width: 640, height: 200),
        NSRect(x: 0, y: 200, width: 640, height: 1_000),
    ])
    func aSelectedElementIsCapturedUpright(_ selection: NSRect) async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let renderHost = BrowserOffscreenRenderHost(webView: webView, viewportSize: webView.bounds.size)
        defer { renderHost.restore() }
        let (loaded, loadedContinuation) = AsyncStream<Void>.makeStream()
        let navigationDelegate = BrowserDesignModeTestNavigationDelegate {
            loadedContinuation.yield()
            loadedContinuation.finish()
        }
        defer { withExtendedLifetime(navigationDelegate) {} }
        webView.navigationDelegate = navigationDelegate
        let half = Int(selection.height / 2)
        webView.loadHTMLString(
            """
            <style>
              html, body { margin: 0; width: 640px; height: 2000px; background: white; }
              .card { position: static; margin-top: \(Int(selection.minY))px; }
              .top { height: \(half)px; background: red; }
              .bottom { height: \(half)px; background: blue; }
            </style>
            <div class="card"><div class="top"></div><div class="bottom"></div></div>
            """,
            baseURL: nil
        )
        let didLoad = await BrowserDesignModeScreenshotEvaluatorTests.awaitPageLoad(loaded)
        #expect(didLoad, "WebKit never finished loading the test page")
        guard didLoad else { return }

        let image = try await BrowserScreenshotWebViewSnapshotter.captureDocumentRect(selection, from: webView)
        let tiffData = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiffData))
        // NSBitmapImageRep.colorAt counts rows from the top of the image.
        let top = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 8)?.usingColorSpace(.deviceRGB))
        let bottom = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh * 7 / 8)?.usingColorSpace(.deviceRGB))

        #expect(top.redComponent > 0.9 && top.blueComponent < 0.1, "top of the selection: \(top)")
        #expect(bottom.blueComponent > 0.9 && bottom.redComponent < 0.1, "bottom of the selection: \(bottom)")
    }
}
