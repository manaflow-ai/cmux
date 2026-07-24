import AppKit
import CmuxBrowser
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct BrowserDesignModeOffscreenSelectionHandoffTests {
    @Test func copyCapturesEveryStackedSelectionAcrossTheFullPage() async throws {
        let visibleImage = solidImage(size: NSSize(width: 640, height: 480))
        let fullPageImage = fullPageImageWithDocumentBands(
            size: NSSize(width: 640, height: 1_800)
        )
        let directory = URL.temporaryDirectory.appendingPathComponent(
            "cmux-design-mode-offscreen-test-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        var visibleCaptureCount = 0
        var fullPageCaptureCount = 0
        var copiedPrompt: String?
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let controller = BrowserDesignModeController(
            surfaceID: UUID(),
            script: BrowserDesignModeScript(),
            promptFormatter: BrowserDesignModePromptFormatter(),
            artifactStore: BrowserDesignModeArtifactStore(directory: directory),
            javaScriptEvaluator: BrowserDesignModeJavaScriptEvaluator(),
            screenshotEvaluator: BrowserDesignModeScreenshotEvaluator(
                timeout: 1,
                visibleViewportCapture: { _, completion in
                    visibleCaptureCount += 1
                    completion(.success(visibleImage))
                },
                fullPageCapture: { _ in
                    fullPageCaptureCount += 1
                    return fullPageImage
                }
            ),
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
        let selectionScreenshots = try selections.map { selection in
            let path = try #require(selection["screenshot_path"] as? String)
            return try #require(NSImage(contentsOfFile: path))
        }
        #expect(selectionScreenshots.map(averageColor(of:)) == [.systemRed, .systemBlue])
        #expect(NSImage(contentsOf: pageScreenshotURL)?.size.height == fullPageImage.size.height)
        #expect(visibleCaptureCount == 2)
        #expect(fullPageCaptureCount == 1)
        _ = navigationDelegate
    }

    @Test func copyFallsBackToBoundedSelectionCapturesWhenFullPageCaptureIsTooLarge() async throws {
        let visibleImage = solidImage(size: NSSize(width: 640, height: 480))
        let directory = URL.temporaryDirectory.appendingPathComponent(
            "cmux-design-mode-large-page-fallback-test-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        var copiedPrompt: String?
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let controller = BrowserDesignModeController(
            surfaceID: UUID(),
            script: BrowserDesignModeScript(),
            promptFormatter: BrowserDesignModePromptFormatter(),
            artifactStore: BrowserDesignModeArtifactStore(directory: directory),
            javaScriptEvaluator: BrowserDesignModeJavaScriptEvaluator(),
            screenshotEvaluator: BrowserDesignModeScreenshotEvaluator(
                timeout: 1,
                visibleViewportCapture: { _, completion in
                    completion(.success(visibleImage))
                },
                fullPageCapture: { _ in
                    throw BrowserScreenshotError.captureAreaTooLarge
                }
            ),
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
              html, body { margin: 0; height: 80000px; }
              button { position: absolute; left: 20px; width: 120px; height: 40px; }
              #first { top: 20px; background: red; }
              #second { top: 79000px; background: blue; }
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
        _ = try await evaluator.call(
            """
            const runtime = globalThis.__cmuxDesignMode;
            runtime.select('#first');
            const second = document.querySelector('#second');
            second.scrollIntoView({ block: 'center' });
            const bounds = second.getBoundingClientRect();
            document.dispatchEvent(new MouseEvent('click', {
                bubbles: true,
                cancelable: true,
                composed: true,
                button: 0,
                clientX: bounds.left + bounds.width / 2,
                clientY: bounds.top + bounds.height / 2,
                shiftKey: true,
            }));
            return runtime.composerState();
            """,
            arguments: [:],
            in: webView,
            contentWorld: BrowserDesignModeController.contentWorld
        )

        await controller.copySelection()

        let prompt = try #require(copiedPrompt)
        let contextURL = try artifactURL(in: prompt, marker: "Full context JSON: ")
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: contextURL)) as? [String: Any]
        )
        let selections = try #require(payload["selections"] as? [[String: Any]])
        #expect(selections.count == 2)
        #expect(selections.allSatisfy {
            guard let path = $0["screenshot_path"] as? String else { return false }
            return FileManager.default.fileExists(atPath: path)
        })
        #expect(payload["page_screenshot_path"] == nil)
        #expect(!prompt.contains("Full-page screenshot:"))
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

    private func fullPageImageWithDocumentBands(size: NSSize) -> NSImage {
        let image = solidImage(size: size)
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 1_500, width: size.width, height: 300).fill()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 100, width: size.width, height: 400).fill()
        image.unlockFocus()
        return image
    }

    private func averageColor(of image: NSImage) -> NSColor {
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let color = bitmap.colorAt(
                  x: bitmap.pixelsWide / 2,
                  y: bitmap.pixelsHigh / 2
              )?.usingColorSpace(.deviceRGB) else { return .clear }
        let red = color.redComponent
        let blue = color.blueComponent
        return red > blue ? .systemRed : .systemBlue
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
