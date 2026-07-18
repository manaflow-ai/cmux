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

    @Test func screenshotPruningPinsOnlyLiveAnnotationContext() async throws {
        let directory = URL.temporaryDirectory
            .appendingPathComponent("cmux-design-mode-pinning-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserDesignModeScreenshotStore(directory: directory)
        let surfaceID = UUID()
        let pinned = try await store.save(
            Data([0]),
            surfaceID: surfaceID,
            retention: .liveContext
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: pinned.path
        )

        for value in 1...101 {
            _ = try await store.save(Data([UInt8(value)]), surfaceID: surfaceID)
        }
        #expect(FileManager.default.fileExists(atPath: pinned.path))

        await store.release(pinned)
        _ = try await store.save(Data([255]), surfaceID: surfaceID)
        #expect(!FileManager.default.fileExists(atPath: pinned.path))
    }

    @Test func releasingLiveAnnotationImmediatelyRestoresScreenshotLimit() async throws {
        let directory = URL.temporaryDirectory
            .appendingPathComponent("cmux-design-mode-release-pruning-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserDesignModeScreenshotStore(directory: directory)
        let surfaceID = UUID()
        var pinned: [URL] = []

        for value in 0...100 {
            pinned.append(try await store.save(
                Data([UInt8(value)]),
                surfaceID: surfaceID,
                retention: .liveContext
            ))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 101)

        await store.release(pinned[0])

        #expect(!FileManager.default.fileExists(atPath: pinned[0].path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 100)
        for url in pinned.dropFirst() {
            await store.remove(url)
        }
    }

    @Test func synthesizedClickKeepsPageRuntimeOutOfTheNativeComposerInputPath() async throws {
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

        #expect(state["visible"] as? Bool == false)
        #expect(state["tag_name"] as? String == "button")
        #expect(state["can_copy"] as? Bool == true)
        #expect(state["focused"] as? Bool == false)
        #expect(state["requested_change"] == nil)
        _ = navigationDelegate
    }

    @Test func sharedDesignModeActivationDeactivatesReactGrab() async throws {
        let panel = await loadedBrowserPanel()
        panel.handleReactGrabBridgeMessage(.stateChange(isActive: true))

        let enabled = await panel.setDesignModeEnabled(true, reason: "test.designMode")

        #expect(enabled)
        #expect(panel.designModeController.isActive)
        #expect(!panel.isReactGrabActive)
    }

    @Test func sharedReactGrabActivationPreparationDeactivatesDesignMode() async throws {
        let panel = await loadedBrowserPanel()
        #expect(await panel.setDesignModeEnabled(true, reason: "test.designMode"))

        let prepared = await panel.prepareForReactGrabActivation(reason: "test.reactGrab")

        #expect(prepared)
        #expect(!panel.designModeController.isActive)
    }

    @Test func nativeAnnotationLifecycleRejectsDrawMessagesOutsideDrawMode() {
        let controller = makeDetachedController()
        controller.phase = .active(annotation: .idle)

        controller.beginAnnotationDrawing(id: "stale-stroke")

        #expect(controller.phase == .active(annotation: .idle))
    }

    @Test func annotationCaptureRequestMustMatchTheActiveStroke() throws {
        let controller = makeDetachedController()
        controller.phase = .active(annotation: .idle)
        controller.adoptInteractionModeFromRuntime("draw")
        controller.beginAnnotationDrawing(id: "active-stroke")
        let staleRequest = BrowserDesignModeAnnotationCaptureRequest(
            id: "stale-stroke",
            strokeBounds: BrowserDesignModeRect(x: 10, y: 20, width: 100, height: 80),
            viewport: BrowserDesignModeViewport(width: 800, height: 600),
            scrollX: 0,
            scrollY: 0
        )

        controller.receiveAnnotationCaptureRequestData(try JSONEncoder().encode(staleRequest))

        #expect(controller.phase == .active(annotation: .drawing(id: "active-stroke")))
    }

    @Test func escapeTreatsInFlightInkAsPromptContent() async {
        let controller = makeDetachedController()
        controller.phase = .active(annotation: .drawing(id: "active-stroke"))

        await controller.handleEscape()

        #expect(controller.phase == .active(annotation: .drawing(id: "active-stroke")))
    }

    @Test func failedModeSwitchPreservesAnInFlightAnnotationCommit() async {
        let controller = makeDetachedController()
        let webView = WKWebView()
        controller.install(on: webView)
        let request = BrowserDesignModeAnnotationCaptureRequest(
            id: "active-stroke",
            strokeBounds: BrowserDesignModeRect(x: 10, y: 10, width: 100, height: 100),
            viewport: BrowserDesignModeViewport(width: 800, height: 600),
            scrollX: 0,
            scrollY: 0
        )
        controller.phase = .active(annotation: .capturing(request))
        controller.adoptInteractionModeFromRuntime("draw")
        let captureRevision = controller.operationRevision

        await controller.setInteractionMode(.select)

        #expect(controller.operationRevision == captureRevision)
        #expect(controller.interactionMode == .draw)
        #expect(controller.phase == .active(annotation: .capturing(request)))
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
        var captureCoverStates: [Bool] = []
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        container.addSubview(webView)
        let controller = BrowserDesignModeController(
            surfaceID: UUID(),
            script: BrowserDesignModeScript(),
            promptFormatter: BrowserDesignModePromptFormatter(),
            screenshotStore: BrowserDesignModeScreenshotStore(directory: directory),
            javaScriptEvaluator: BrowserDesignModeJavaScriptEvaluator(),
            screenshotEvaluator: BrowserDesignModeScreenshotEvaluator(timeout: 1) { capturedWebView, completion in
                captureCoverStates.append(
                    capturedWebView.superview?.subviews.contains(where: { $0 !== capturedWebView }) == true
                )
                completion(.success(image))
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
            return globalThis.__cmuxDesignMode?.composerState();
            """,
            arguments: [:],
            in: webView,
            contentWorld: BrowserDesignModeController.contentWorld
        )
        #expect(controller.snapshot?.edits.isEmpty == true)
        #expect((state as? [String: Any])?["can_copy"] as? Bool == true)
        #expect((state as? [String: Any])?["requested_change"] == nil)

        await controller.copySelection()

        #expect(captureCoverStates == [false, true, true])
        #expect(container.subviews == [webView])
        let prompt = try #require(copiedPrompt)
        #expect(prompt.contains("<cmux_design_mode>"))
        #expect(try requestedChange(from: prompt) == "")
        _ = navigationDelegate
    }

    @Test func hoverInspectionContinuesWhileDistinctClicksStackReferencesForCopy() async throws {
        let image = NSImage(size: NSSize(width: 640, height: 480))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()

        let directory = URL.temporaryDirectory
            .appendingPathComponent("cmux-design-mode-stack-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var copiedPrompt: String?
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
        webView.loadHTMLString(
            """
            <main>
              <button id="first">First</button>
              <button id="second">Second</button>
            </main>
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
            const bounds = second.getBoundingClientRect();
            const eventInit = {
                bubbles: true,
                cancelable: true,
                composed: true,
                button: 0,
                clientX: bounds.left + bounds.width / 2,
                clientY: bounds.top + bounds.height / 2,
            };
            document.dispatchEvent(new PointerEvent('pointermove', eventInit));
            const hover = runtime.composerState();
            document.dispatchEvent(new MouseEvent('click', { ...eventInit, shiftKey: true }));
            const stacked = runtime.composerState();
            return { hover, stacked };
            """,
            arguments: [:],
            in: webView,
            contentWorld: BrowserDesignModeController.contentWorld
        )
        let state = try #require(value as? [String: Any])
        let hover = try #require(state["hover"] as? [String: Any])
        let stacked = try #require(state["stacked"] as? [String: Any])

        #expect(hover["visible"] as? Bool == false)
        #expect(hover["hovered_selector"] as? String == "#second")
        #expect(hover["selection_count"] as? Int == 1)
        #expect(stacked["selection_count"] as? Int == 2)
        #expect(stacked["selectors"] as? [String] == ["#first", "#second"])

        await controller.copySelection()

        let prompt = try #require(copiedPrompt)
        let initialPayload = try payload(from: prompt)
        let elements = try #require(initialPayload["elements"] as? [[String: Any]])
        #expect(elements.count == 2)
        #expect((elements[0]["selection"] as? [String: Any])?["selector"] as? String == "#first")
        #expect((elements[1]["selection"] as? [String: Any])?["selector"] as? String == "#second")
        #expect(elements.allSatisfy { ($0["screenshot_path"] as? String)?.isEmpty == false })

        controller.requestedChange = "Keep the second selection"
        await controller.removeSelection(at: 0)
        #expect(controller.snapshot?.selections.map(\.selector) == ["#second"])
        #expect(controller.requestedChange == "Keep the second selection")

        await controller.copySelection()

        let reducedPrompt = try #require(copiedPrompt)
        let reducedPayload = try payload(from: reducedPrompt)
        let reducedElements = try #require(reducedPayload["elements"] as? [[String: Any]])
        #expect(reducedElements.count == 1)
        #expect((reducedElements[0]["selection"] as? [String: Any])?["selector"] as? String == "#second")
        #expect(reducedPayload["requested_change"] as? String == "Keep the second selection")
        _ = navigationDelegate
    }

    private func requestedChange(from prompt: String) throws -> String? {
        try payload(from: prompt)["requested_change"] as? String
    }

    private func makeDetachedController() -> BrowserDesignModeController {
        BrowserDesignModeController(
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
    }

    private func payload(from prompt: String) throws -> [String: Any] {
        let marker = "Payload:\n"
        let start = try #require(prompt.range(of: marker)?.upperBound)
        let end = try #require(
            prompt.range(of: "\n</cmux_design_mode>", range: start..<prompt.endIndex)?.lowerBound
        )
        let data = try #require(Data(base64Encoded: String(prompt[start..<end])))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func loadedBrowserPanel() async -> BrowserPanel {
        let panel = BrowserPanel(workspaceId: UUID())
        let (loaded, loadedContinuation) = AsyncStream<Void>.makeStream()
        let existingDidFinish = panel.navigationDelegate?.didFinish
        panel.navigationDelegate?.didFinish = { webView in
            existingDidFinish?(webView)
            loadedContinuation.yield()
            loadedContinuation.finish()
        }
        panel.navigate(to: URL(string: "about:blank")!)
        var iterator = loaded.makeAsyncIterator()
        _ = await iterator.next()
        return panel
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
