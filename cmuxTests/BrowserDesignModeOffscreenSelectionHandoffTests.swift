import AppKit
import CmuxBrowser
import Foundation
import Testing
import WebKit

@Suite(.serialized)
@MainActor
struct BrowserDesignModeOffscreenSelectionHandoffTests {
    @Test func copyCapturesEveryStackedSelectionAcrossTheFullPage() async throws {
        let visibleImage = solidImage(size: NSSize(width: 640, height: 480))
        let fullPageImage = solidImage(size: NSSize(width: 640, height: 1_800))
        let directory = URL.temporaryDirectory.appendingPathComponent(
            "cmux-design-mode-offscreen-test-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        var captureCount = 0
        var copiedPrompt: String?
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let controller = BrowserDesignModeController(
            surfaceID: UUID(),
            script: BrowserDesignModeScript(),
            promptFormatter: BrowserDesignModePromptFormatter(),
            artifactStore: BrowserDesignModeArtifactStore(directory: directory),
            javaScriptEvaluator: BrowserDesignModeJavaScriptEvaluator(),
            screenshotEvaluator: BrowserDesignModeScreenshotEvaluator(timeout: 1) { _, completion in
                captureCount += 1
                completion(.success(captureCount == 2 ? fullPageImage : visibleImage))
            },
            canEnable: { true },
            clipboardWriter: { prompt in
                copiedPrompt = prompt
                return true
            },
            onActivityChanged: {}
        )
        controller.install(on: webView)

        let (loaded, loadedContinuation) = AsyncStream<Void>.makeStream()
        let navigationDelegate = BrowserDesignModeOffscreenNavigationDelegate {
            loadedContinuation.yield()
            loadedContinuation.finish()
        }
        webView.navigationDelegate = navigationDelegate
        webView.loadHTMLString(
            """
            <style>
              html, body { margin: 0; height: 1800px; }
              button { position: absolute; left: 20px; width: 120px; height: 40px; }
              #first { top: 20px; }
              #second { top: 1500px; }
            </style>
            <button id="first">First</button>
            <button id="second">Second</button>
            """,
            baseURL: nil
        )
        var loadedIterator = loaded.makeAsyncIterator()
        _ = await loadedIterator.next()

        #expect(await controller.setEnabled(true, reason: "test"))
        let evaluator = BrowserDesignModeJavaScriptEvaluator()
        let value = try await evaluator.call(
            """
            const runtime = globalThis.__cmuxDesignMode;
            runtime.select('#first');
            const second = document.querySelector('#second');
            second.scrollIntoView({ block: 'center' });
            const bounds = second.getBoundingClientRect();
            const eventInit = {
                bubbles: true,
                cancelable: true,
                composed: true,
                button: 0,
                clientX: bounds.left + bounds.width / 2,
                clientY: bounds.top + bounds.height / 2,
                shiftKey: true,
            };
            document.dispatchEvent(new MouseEvent('click', eventInit));
            return runtime.composerState();
            """,
            arguments: [:],
            in: webView,
            contentWorld: BrowserDesignModeController.contentWorld
        )
        let state = try #require(value as? [String: Any])
        #expect(state["selection_count"] as? Int == 2)

        await controller.copySelection()

        let prompt = try #require(copiedPrompt)
        let contextURL = try artifactURL(in: prompt, marker: "Full context JSON: ")
        let pageScreenshotURL = try artifactURL(in: prompt, marker: "Full-page screenshot: ")
        let payloadData = try Data(contentsOf: contextURL)
        let payload = try #require(
            JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        )
        let selections = try #require(payload["selections"] as? [[String: Any]])

        #expect(selections.count == 2)
        #expect(selections.allSatisfy {
            ($0["screenshot_path"] as? String)?.isEmpty == false
        })
        #expect(selections.allSatisfy {
            (($0["viewport"] as? [String: Any])?["scroll_y"] as? Double) != nil
        })
        #expect(NSImage(contentsOf: pageScreenshotURL)?.size.height == fullPageImage.size.height)
        #expect(captureCount == 3)
        _ = navigationDelegate
    }

    private func solidImage(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    private func artifactURL(in prompt: String, marker: String) throws -> URL {
        let start = try #require(prompt.range(of: marker)?.upperBound)
        let end = prompt[start...].firstIndex(of: "\n") ?? prompt.endIndex
        return URL(fileURLWithPath: String(prompt[start..<end]))
    }
}

private final class BrowserDesignModeOffscreenNavigationDelegate: NSObject, WKNavigationDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        onFinish()
    }
}
