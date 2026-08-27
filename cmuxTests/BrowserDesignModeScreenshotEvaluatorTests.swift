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
        var lateCompletion: (@MainActor (Result<NSImage, any Error>) -> Void)?
        let expected = NSImage(size: NSSize(width: 20, height: 10))
        let evaluator = BrowserDesignModeScreenshotEvaluator(timeout: 60) { _, completion in
            lateCompletion = completion
            startedContinuation.yield(())
        }
        let task = Task { @MainActor in
            try await evaluator.captureVisibleViewport(from: WKWebView())
        }
        var startedIterator = started.makeAsyncIterator()
        _ = await startedIterator.next()

        evaluator.cancelAll()
        lateCompletion?(.success(expected))
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

    @Test func droppedVisibleCaptureCallbackRecoversAfterBoundedQuarantine() async {
        let expected = NSImage(size: NSSize(width: 20, height: 10))
        var captureStartCount = 0
        var firstCompletion: (@MainActor (Result<NSImage, any Error>) -> Void)?
        let webView = WKWebView()
        let evaluator = BrowserDesignModeScreenshotEvaluator(
            timeout: 0.01,
            cleanupTimeout: 0.02
        ) { _, completion in
            captureStartCount += 1
            if captureStartCount == 1 {
                firstCompletion = completion
            } else {
                completion(.success(expected))
            }
        }

        do {
            _ = try await evaluator.captureVisibleViewport(from: webView)
            Issue.record("Expected first capture timeout")
        } catch {
            #expect(error as? BrowserDesignModeError == .operationTimedOut)
        }

        do {
            _ = try await evaluator.captureVisibleViewport(from: webView)
            Issue.record("Expected quarantine to block an immediate retry")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(captureStartCount == 1)

        let recoveryDeadline = ContinuousClock.now + .seconds(1)
        var recoveredCapture: NSImage?
        while recoveredCapture == nil, ContinuousClock.now < recoveryDeadline {
            do {
                recoveredCapture = try await evaluator.captureVisibleViewport(from: webView)
            } catch is CancellationError {
                await Task.yield()
            } catch {
                Issue.record("Expected capture to recover after quarantine: \(error)")
                break
            }
        }
        #expect(recoveredCapture === expected)
        #expect(captureStartCount == 2)

        firstCompletion?(.success(expected))
    }

    @Test func fullPageCaptureCanOutliveSingleViewportDeadline() async throws {
        let expected = NSImage(size: NSSize(width: 20, height: 40))
        let evaluator = BrowserDesignModeScreenshotEvaluator(
            timeout: 0.2,
            visibleViewportCapture: { _, _ in },
            fullPageCapture: { _, onProgress in
                for _ in 0..<5 {
                    try await ContinuousClock().sleep(for: .milliseconds(50))
                    onProgress()
                }
                return expected
            }
        )

        let captured = try await evaluator.captureFullPage(from: WKWebView())

        #expect(captured === expected)
    }

    @Test func progressingDocumentCaptureCanOutliveSingleDeadline() async throws {
        let expected = NSImage(size: NSSize(width: 20, height: 40))
        let evaluator = BrowserDesignModeScreenshotEvaluator(
            timeout: 0.2,
            visibleViewportCapture: { _, _ in },
            fullPageCapture: { _, _ in expected },
            documentRectCapture: { _, _, onProgress in
                for _ in 0..<5 {
                    try await ContinuousClock().sleep(for: .milliseconds(50))
                    onProgress()
                }
                return expected
            }
        )

        let captured = try await evaluator.captureDocumentRect(
            NSRect(x: 0, y: 0, width: 20, height: 40),
            from: WKWebView()
        )

        #expect(captured === expected)
    }

    @Test func timeoutWaitsForCaptureCleanupBeforeCallerStartsFallback() async throws {
        var events: [String] = []
        var cleanupContinuation: CheckedContinuation<Void, Never>?
        let (cleanupStarted, cleanupStartedContinuation) = AsyncStream<Void>.makeStream()
        let evaluator = BrowserDesignModeScreenshotEvaluator(
            timeout: 0.01,
            visibleViewportCapture: { _, _ in },
            fullPageCapture: { _, _ in
                do {
                    try await ContinuousClock().sleep(for: .seconds(60))
                    return NSImage(size: NSSize(width: 20, height: 40))
                } catch {
                    events.append("cleanup-started")
                    await withCheckedContinuation { continuation in
                        cleanupContinuation = continuation
                        cleanupStartedContinuation.yield()
                    }
                    events.append("cleanup-finished")
                    throw error
                }
            },
            documentRectCapture: { _, _, _ in
                events.append("fallback")
                return NSImage(size: NSSize(width: 10, height: 10))
            }
        )
        let owner = Task { @MainActor in
            do {
                _ = try await evaluator.captureFullPage(from: WKWebView())
                Issue.record("Expected full-page capture timeout")
            } catch {
                #expect(error as? BrowserDesignModeError == .operationTimedOut)
                _ = try await evaluator.captureDocumentRect(
                    NSRect(x: 0, y: 0, width: 10, height: 10),
                    from: WKWebView()
                )
            }
        }

        var cleanupStartedIterator = cleanupStarted.makeAsyncIterator()
        _ = await cleanupStartedIterator.next()
        await Task.yield()
        #expect(events == ["cleanup-started"])

        cleanupContinuation?.resume()
        cleanupStartedContinuation.finish()
        try await owner.value

        #expect(events == ["cleanup-started", "cleanup-finished", "fallback"])
    }

    @Test func callerCancellationWaitsForCaptureCleanup() async {
        var events: [String] = []
        var cleanupContinuation: CheckedContinuation<Void, Never>?
        let (captureStarted, captureStartedContinuation) = AsyncStream<Void>.makeStream()
        let (cleanupStarted, cleanupStartedContinuation) = AsyncStream<Void>.makeStream()
        let evaluator = BrowserDesignModeScreenshotEvaluator(
            timeout: 60,
            visibleViewportCapture: { _, _ in },
            fullPageCapture: { _, _ in
                captureStartedContinuation.yield()
                do {
                    try await ContinuousClock().sleep(for: .seconds(60))
                    return NSImage(size: NSSize(width: 20, height: 40))
                } catch {
                    events.append("cleanup-started")
                    await withCheckedContinuation { continuation in
                        cleanupContinuation = continuation
                        cleanupStartedContinuation.yield()
                    }
                    events.append("cleanup-finished")
                    throw error
                }
            }
        )
        var ownerFinished = false
        let owner = Task { @MainActor in
            defer { ownerFinished = true }
            do {
                _ = try await evaluator.captureFullPage(from: WKWebView())
                Issue.record("Expected full-page capture cancellation")
            } catch {
                #expect(error is CancellationError)
            }
        }

        var captureStartedIterator = captureStarted.makeAsyncIterator()
        _ = await captureStartedIterator.next()
        owner.cancel()

        var cleanupStartedIterator = cleanupStarted.makeAsyncIterator()
        _ = await cleanupStartedIterator.next()
        await Task.yield()
        #expect(!ownerFinished)
        #expect(events == ["cleanup-started"])

        cleanupContinuation?.resume()
        captureStartedContinuation.finish()
        cleanupStartedContinuation.finish()
        await owner.value

        #expect(ownerFinished)
        #expect(events == ["cleanup-started", "cleanup-finished"])
    }

    @Test func uncooperativeCaptureCannotDefeatTimeoutOrStartFallback() async {
        var captureContinuation: CheckedContinuation<NSImage, Never>?
        var didStartFallback = false
        let (captureStarted, captureStartedContinuation) = AsyncStream<Void>.makeStream()
        let evaluator = BrowserDesignModeScreenshotEvaluator(
            timeout: 0.01,
            cleanupTimeout: 0.01,
            visibleViewportCapture: { _, _ in },
            fullPageCapture: { _, _ in
                await withCheckedContinuation { continuation in
                    captureContinuation = continuation
                    captureStartedContinuation.yield()
                }
            },
            documentRectCapture: { _, _, _ in
                didStartFallback = true
                return NSImage(size: NSSize(width: 10, height: 10))
            }
        )
        let owner = Task { @MainActor in
            do {
                _ = try await evaluator.captureFullPage(from: WKWebView())
                Issue.record("Expected full-page capture cancellation")
            } catch is CancellationError {
                return
            } catch {
                _ = try? await evaluator.captureDocumentRect(
                    NSRect(x: 0, y: 0, width: 10, height: 10),
                    from: WKWebView()
                )
            }
        }

        var captureStartedIterator = captureStarted.makeAsyncIterator()
        _ = await captureStartedIterator.next()
        await owner.value

        #expect(!didStartFallback)
        captureContinuation?.resume(returning: NSImage(size: NSSize(width: 20, height: 40)))
        captureStartedContinuation.finish()
    }

    @Test func uncooperativeCaptureBlocksRetriesForTheSameWebView() async {
        var captureContinuations: [CheckedContinuation<NSImage, Never>] = []
        var captureStartCount = 0
        let webView = WKWebView()
        let evaluator = BrowserDesignModeScreenshotEvaluator(
            timeout: 0.01,
            cleanupTimeout: 0.01,
            visibleViewportCapture: { _, _ in },
            fullPageCapture: { _, _ in
                captureStartCount += 1
                return await withCheckedContinuation { continuation in
                    captureContinuations.append(continuation)
                }
            }
        )

        for _ in 0..<2 {
            do {
                _ = try await evaluator.captureFullPage(from: webView)
                Issue.record("Expected capture cancellation")
            } catch {
                #expect(error is CancellationError)
            }
        }

        #expect(captureStartCount == 1)
        for continuation in captureContinuations {
            continuation.resume(returning: NSImage(size: NSSize(width: 20, height: 40)))
        }
    }

    @Test func designModeFullPageOverviewUsesBoundedWebKitOutput() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let (loaded, loadedContinuation) = AsyncStream<Void>.makeStream()
        let navigationDelegate = BrowserDesignModeTestNavigationDelegate {
            loadedContinuation.yield()
            loadedContinuation.finish()
        }
        webView.navigationDelegate = navigationDelegate
        webView.loadHTMLString(
            """
            <style>
              html, body { margin: 0; width: 3000px; height: 2000px; }
              body { background: linear-gradient(#f00, #00f); }
            </style>
            """,
            baseURL: nil
        )
        var loadedIterator = loaded.makeAsyncIterator()
        _ = await loadedIterator.next()

        let image = try await BrowserScreenshotWebViewSnapshotter.captureBoundedFullPageOverview(
            from: webView,
            maximumPixelCount: BrowserScreenshotPasteboardWriter.maximumDesignModeArtifactPixelCount
        )
        let representation = try #require(image.representations.first)
        let pixelCount = representation.pixelsWide * representation.pixelsHigh

        #expect(pixelCount <= BrowserScreenshotPasteboardWriter.maximumDesignModeArtifactPixelCount)
        #expect(Int(image.size.width * image.size.height) <= 4_194_304)
        #expect(abs(image.size.width / image.size.height - 1.5) < 0.01)
        _ = navigationDelegate
    }

    @Test func zoomedPageUsesBoundedStitchedOverviewAndSelectionCapture() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let (loaded, loadedContinuation) = AsyncStream<Void>.makeStream()
        let navigationDelegate = BrowserDesignModeTestNavigationDelegate {
            loadedContinuation.yield()
            loadedContinuation.finish()
        }
        webView.navigationDelegate = navigationDelegate
        webView.loadHTMLString(
            """
            <style>
              html, body { margin: 0; width: 1200px; height: 800px; }
              body { background: linear-gradient(90deg, #f00, #00f); }
            </style>
            """,
            baseURL: nil
        )
        var loadedIterator = loaded.makeAsyncIterator()
        _ = await loadedIterator.next()
        webView.pageZoom = 2

        let screenshotEvaluator = BrowserDesignModeScreenshotEvaluator(
            timeout: 10,
            cleanupTimeout: 2
        )
        let overview = try await screenshotEvaluator.captureFullPage(from: webView)
        let selection = try await screenshotEvaluator.captureDocumentRect(
            NSRect(x: 200, y: 200, width: 1_200, height: 800),
            from: webView
        )

        let overviewRep = try #require(overview.representations.first)
        let selectionRep = try #require(selection.representations.first)
        #expect(overviewRep.pixelsWide * overviewRep.pixelsHigh <= 4_194_304)
        #expect(selectionRep.pixelsWide * selectionRep.pixelsHigh <= 4_194_304)
        #expect(selection.size.width > 0)
        #expect(selection.size.height > 0)
        _ = navigationDelegate
    }

    @Test func smoothScrollingPageCapturesRequestedRegionAndRestoresOffset() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let (loaded, loadedContinuation) = AsyncStream<Void>.makeStream()
        let navigationDelegate = BrowserDesignModeTestNavigationDelegate {
            loadedContinuation.yield()
            loadedContinuation.finish()
        }
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
        var loadedIterator = loaded.makeAsyncIterator()
        _ = await loadedIterator.next()

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
        _ = navigationDelegate
    }

    @Test func synthesizedClickKeepsPageRuntimeOutOfTheNativeComposerInputPath() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let controller = BrowserDesignModeController(
            surfaceID: UUID(),
            script: BrowserDesignModeScript(),
            promptFormatter: BrowserDesignModePromptFormatter(),
            artifactStore: BrowserDesignModeArtifactStore(directory: URL.temporaryDirectory),
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
        let artifactStore = BrowserDesignModeArtifactStore(directory: directory)
        for value in 0..<99 {
            _ = try await artifactStore.saveScreenshot(
                Data([UInt8(value)]),
                surfaceID: UUID(),
                retention: .liveContext
            )
        }
        var copiedPrompt: String?
        var captureCoverStates: [Bool] = []
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        container.addSubview(webView)
        let controller = BrowserDesignModeController(
            surfaceID: UUID(),
            script: BrowserDesignModeScript(),
            promptFormatter: BrowserDesignModePromptFormatter(),
            artifactStore: artifactStore,
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
        #expect(!prompt.contains("<cmux_design_mode>"))
        #expect(!prompt.contains("base64"))
        #expect(!prompt.contains("Full-page screenshot:"))
        #expect(!prompt.contains("Selection 1"))
        let contextURL = try contextURL(from: prompt)
        let processDirectory = contextURL.deletingLastPathComponent()
        #expect(processDirectory.deletingLastPathComponent() == directory)
        #expect(processDirectory.lastPathComponent.hasPrefix("process-"))
        #expect(try requestedChange(from: prompt) == "")
        let context = try payload(from: prompt)
        let selections = try #require(context["selections"] as? [[String: Any]])
        let selectionPath = try #require(selections.first?["screenshot_path"] as? String)
        let pagePath = try #require(context["page_screenshot_path"] as? String)
        #expect(prompt.contains(selectionPath))
        #expect(!prompt.contains(pagePath))
        #expect(FileManager.default.fileExists(atPath: selectionPath))
        #expect(FileManager.default.fileExists(atPath: pagePath))
        #expect(FileManager.default.fileExists(atPath: contextURL.path))
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
            artifactStore: BrowserDesignModeArtifactStore(directory: directory),
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
        let selections = try #require(initialPayload["selections"] as? [[String: Any]])
        #expect(selections.count == 2)
        #expect(selections[0]["selector"] as? String == "#first")
        #expect(selections[1]["selector"] as? String == "#second")
        #expect(selections.allSatisfy { ($0["screenshot_path"] as? String)?.isEmpty == false })

        controller.requestedChange = "Keep the second selection"
        await controller.removeSelection(at: 0)
        #expect(controller.snapshot?.selections.map(\.selector) == ["#second"])
        #expect(controller.requestedChange == "Keep the second selection")

        await controller.copySelection()

        let reducedPrompt = try #require(copiedPrompt)
        let reducedPayload = try payload(from: reducedPrompt)
        let reducedSelections = try #require(reducedPayload["selections"] as? [[String: Any]])
        #expect(reducedSelections.count == 1)
        #expect(reducedSelections[0]["selector"] as? String == "#second")
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
            artifactStore: BrowserDesignModeArtifactStore(directory: URL.temporaryDirectory),
            javaScriptEvaluator: BrowserDesignModeJavaScriptEvaluator(),
            screenshotEvaluator: BrowserDesignModeScreenshotEvaluator(),
            canEnable: { true },
            clipboardWriter: { _ in true },
            onActivityChanged: {}
        )
    }

    private func payload(from prompt: String) throws -> [String: Any] {
        let data = try Data(contentsOf: contextURL(from: prompt))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func contextURL(from prompt: String) throws -> URL {
        let marker = "Details: "
        let start = try #require(prompt.range(of: marker)?.upperBound)
        let end = prompt[start...].firstIndex(of: "\n") ?? prompt.endIndex
        return URL(fileURLWithPath: String(prompt[start..<end]))
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
