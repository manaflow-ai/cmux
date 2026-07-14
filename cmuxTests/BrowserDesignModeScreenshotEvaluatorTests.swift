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
struct BrowserDesignModeScreenshotEvaluatorTests {
    @Test func returnsCompletedCapture() async throws {
        let expected = NSImage(size: NSSize(width: 20, height: 10))
        let evaluator = BrowserDesignModeScreenshotEvaluator(timeout: 1) { _, completion in
            completion(.success(expected))
        }

        let captured = try await evaluator.captureVisibleViewport(from: WKWebView())

        #expect(captured === expected)
    }

    @Test func cancelAllReleasesPendingCapture() async {
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let evaluator = BrowserDesignModeScreenshotEvaluator(timeout: 60) { _, _ in
            startedContinuation.yield(())
        }
        let task = Task { @MainActor in
            try await evaluator.captureVisibleViewport(from: WKWebView())
        }
        var startedIterator = started.makeAsyncIterator()
        _ = await startedIterator.next()

        evaluator.cancelAll()
        startedContinuation.finish()

        do {
            _ = try await task.value
            Issue.record("Expected capture cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func timesOutWhenWebKitDoesNotComplete() async {
        let evaluator = BrowserDesignModeScreenshotEvaluator(timeout: 0) { _, _ in }

        do {
            _ = try await evaluator.captureVisibleViewport(from: WKWebView())
            Issue.record("Expected capture timeout")
        } catch {
            #expect(error as? BrowserDesignModeError == .operationTimedOut)
        }
    }

    @Test func synthesizedClickPresentsComposerAutomatically() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let controller = BrowserDesignModeController(
            surfaceID: UUID(),
            script: BrowserDesignModeScript(),
            promptFormatter: BrowserDesignModePromptFormatter(),
            screenshotStore: BrowserDesignModeScreenshotStore(directory: URL.temporaryDirectory),
            javaScriptEvaluator: BrowserDesignModeJavaScriptEvaluator(),
            screenshotEvaluator: BrowserDesignModeScreenshotEvaluator(),
            canEnable: { true },
            clipboardWriter: { _ in true },
            onActivityChanged: {}
        )
        controller.install(on: webView)

        let (loaded, loadedContinuation) = AsyncStream<Void>.makeStream()
        let navigationDelegate = BrowserDesignModeTestNavigationDelegate {
            loadedContinuation.yield()
            loadedContinuation.finish()
        }
        webView.navigationDelegate = navigationDelegate
        webView.loadHTMLString("<main><button id='target'>Target</button></main>", baseURL: nil)
        var loadedIterator = loaded.makeAsyncIterator()
        _ = await loadedIterator.next()

        let enabled = await controller.setEnabled(true, reason: "test")
        #expect(enabled)
        let evaluator = BrowserDesignModeJavaScriptEvaluator()
        let value = try await evaluator.call(
            """
            const target = document.querySelector('#target');
            const bounds = target.getBoundingClientRect();
            document.dispatchEvent(new MouseEvent('click', {
                bubbles: true,
                cancelable: true,
                composed: true,
                button: 0,
                clientX: bounds.left + bounds.width / 2,
                clientY: bounds.top + bounds.height / 2,
            }));
            return globalThis.__cmuxDesignMode?.composerState();
            """,
            arguments: [:],
            in: webView,
            contentWorld: BrowserDesignModeController.contentWorld
        )
        let state = try #require(value as? [String: Any])

        #expect(state["visible"] as? Bool == true)
        #expect(state["tag_name"] as? String == "button")
        #expect(state["can_copy"] as? Bool == true)
        #expect(state["focused"] as? Bool == true)
        _ = navigationDelegate
    }

    @Test func composerCopyRequestWritesSelectedContextWithoutDescriptionOrRuntimeEdits() async throws {
        let image = NSImage(size: NSSize(width: 640, height: 480))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()

        let directory = URL.temporaryDirectory
            .appendingPathComponent("cmux-design-mode-copy-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var copiedPrompt: String?
        let (copied, copiedContinuation) = AsyncStream<Void>.makeStream()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let controller = BrowserDesignModeController(
            surfaceID: UUID(),
            script: BrowserDesignModeScript(),
            promptFormatter: BrowserDesignModePromptFormatter(),
            screenshotStore: BrowserDesignModeScreenshotStore(directory: directory),
            javaScriptEvaluator: BrowserDesignModeJavaScriptEvaluator(),
            screenshotEvaluator: BrowserDesignModeScreenshotEvaluator(timeout: 1) { _, completion in
                completion(.success(image))
            },
            canEnable: { true },
            clipboardWriter: { prompt in
                copiedPrompt = prompt
                copiedContinuation.yield()
                copiedContinuation.finish()
                return true
            },
            onActivityChanged: {}
        )
        controller.install(on: webView)

        let (loaded, loadedContinuation) = AsyncStream<Void>.makeStream()
        let navigationDelegate = BrowserDesignModeTestNavigationDelegate {
            loadedContinuation.yield()
            loadedContinuation.finish()
        }
        webView.navigationDelegate = navigationDelegate
        webView.loadHTMLString("<main><button id='target'>Target</button></main>", baseURL: nil)
        var loadedIterator = loaded.makeAsyncIterator()
        _ = await loadedIterator.next()

        #expect(await controller.setEnabled(true, reason: "test"))
        let evaluator = BrowserDesignModeJavaScriptEvaluator()
        let state = try await evaluator.call(
            """
            globalThis.__cmuxDesignMode?.select('#target');
            return globalThis.__cmuxDesignMode?.requestCopy();
            """,
            arguments: [:],
            in: webView,
            contentWorld: BrowserDesignModeController.contentWorld
        )
        #expect(controller.snapshot?.edits.isEmpty == true)
        #expect((state as? [String: Any])?["copy_state"] as? String == "copying")

        var copiedIterator = copied.makeAsyncIterator()
        _ = await copiedIterator.next()

        let prompt = try #require(copiedPrompt)
        #expect(prompt.contains("<cmux_design_mode>"))
        #expect(try requestedChange(from: prompt) == "")
        _ = navigationDelegate
    }

    private func requestedChange(from prompt: String) throws -> String? {
        let marker = "Payload:\n"
        let start = try #require(prompt.range(of: marker)?.upperBound)
        let end = try #require(
            prompt.range(of: "\n</cmux_design_mode>", range: start..<prompt.endIndex)?.lowerBound
        )
        let data = try #require(Data(base64Encoded: String(prompt[start..<end])))
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return payload["requested_change"] as? String
    }
}

private final class BrowserDesignModeTestNavigationDelegate: NSObject, WKNavigationDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        onFinish()
    }
}
