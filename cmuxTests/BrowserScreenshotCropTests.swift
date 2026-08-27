import AppKit
import CmuxBrowser
import CmuxFoundation
import ObjectiveC.runtime
import Testing
import UniformTypeIdentifiers
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserScreenshotCropTests {
    private typealias FocusImplementation = @convention(c) (AnyObject, Selector) -> Void
    private static let imageFocusBackingScaleKey =
        "cmux.browserScreenshotCropTests.imageFocusBackingScale"
    private static let imageFocusOverrideInstalled: Bool = {
        let lockSelector = #selector(NSImage.lockFocus)
        let unlockSelector = #selector(NSImage.unlockFocus)
        guard let lockMethod = class_getInstanceMethod(NSImage.self, lockSelector),
              let unlockMethod = class_getInstanceMethod(NSImage.self, unlockSelector) else {
            return false
        }
        let originalLock = unsafeBitCast(
            method_getImplementation(lockMethod),
            to: FocusImplementation.self
        )
        let originalUnlock = unsafeBitCast(
            method_getImplementation(unlockMethod),
            to: FocusImplementation.self
        )
        let lockBlock: @convention(block) (NSImage) -> Void = { image in
            guard let scale = Thread.current.threadDictionary[imageFocusBackingScaleKey] as? Int else {
                originalLock(image, lockSelector)
                return
            }
            let size = image.size
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width) * scale,
                pixelsHigh: Int(size.height) * scale,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                Issue.record("Could not create the controlled image-focus context")
                originalLock(image, lockSelector)
                return
            }
            bitmap.size = size
            image.addRepresentation(bitmap)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
        }
        let unlockBlock: @convention(block) (NSImage) -> Void = { image in
            guard Thread.current.threadDictionary[imageFocusBackingScaleKey] is Int else {
                originalUnlock(image, unlockSelector)
                return
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        // Keep the replacement IMPs alive for the test process: parallel test
        // threads may already be executing the forwarding path.
        method_setImplementation(lockMethod, imp_implementationWithBlock(lockBlock))
        method_setImplementation(unlockMethod, imp_implementationWithBlock(unlockBlock))
        return true
    }()

    @Test
    func extremeAspectRatioBoundIsConstantTimeAndWithinPixelLimit() throws {
        let size = try BrowserScreenshotCaptureBounds.boundedOutputSize(
            for: NSSize(width: 100_000_000, height: 1),
            maximumPixelCount: 4_194_304
        )
        #expect(size == NSSize(width: 4_194_304, height: 1))
    }

    @Test
    func encodedCropUsesOnePixelPerSnapshotCoordinate() async throws {
        let source = try makePatternedBitmapImage()

        let cropped = try withImageFocusBackingScale(2) {
            try BrowserScreenshotCrop.croppedImage(
                from: source,
                selectionInView: NSRect(x: 50, y: 25, width: 100, height: 50),
                viewBounds: NSRect(x: 0, y: 0, width: 200, height: 150)
            )
        }
        let pngData = try await BrowserScreenshotPasteboardWriter().pngData(for: cropped)
        let bitmap = try #require(NSBitmapImageRep(data: pngData))

        #expect(bitmap.pixelsWide == 200)
        #expect(bitmap.pixelsHigh == 100)
        try expectColor(testRed, atX: 25, y: 25, in: bitmap)
        try expectColor(testGreen, atX: 175, y: 25, in: bitmap)
        try expectColor(testBlue, atX: 25, y: 75, in: bitmap)
        try expectColor(testYellow, atX: 175, y: 75, in: bitmap)
    }

    @Test
    func pasteboardEncodingBoundsLargeImagePixelCount() async throws {
        let width = 2_050
        let height = 2_050
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = NSSize(width: width, height: height)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)

        let item = try await BrowserScreenshotPasteboardWriter(
            maximumPixelCount: BrowserScreenshotPasteboardWriter.maximumDesignModeArtifactPixelCount,
            oversizedImagePolicy: .downscale
        ).pasteboardItem(for: image)
        for type in [UTType.png, UTType.tiff] {
            let data = try #require(item.data(
                forType: NSPasteboard.PasteboardType(type.identifier)
            ))
            let encoded = try #require(NSBitmapImageRep(data: data))
            #expect(encoded.pixelsWide * encoded.pixelsHigh <= 4_194_304)
        }
    }

    @Test
    func ordinaryScreenshotClipboardKeepsNativeResolution() async throws {
        let width = 2_050
        let height = 2_050
        let image = try makeBlankBitmapImage(width: width, height: height)
        let pasteboard = NSPasteboard(
            name: .init("cmux-browser-native-resolution-\(UUID().uuidString)")
        )
        pasteboard.clearContents()

        _ = try await BrowserScreenshotPipeline.captureAndWrite(
            mode: .fullPage,
            snapshot: { image },
            pasteboard: pasteboard
        )

        for type in [UTType.png, UTType.tiff] {
            let data = try #require(pasteboard.data(
                forType: NSPasteboard.PasteboardType(type.identifier)
            ))
            let encoded = try #require(NSBitmapImageRep(data: data))
            #expect(encoded.pixelsWide == width)
            #expect(encoded.pixelsHigh == height)
        }
    }

    @Test
    func ordinaryScreenshotRejectsUnsafeEncodingInsteadOfDownscaling() async throws {
        let image = try makeBlankBitmapImage(width: 11, height: 10)

        do {
            _ = try await BrowserScreenshotPasteboardWriter(
                maximumPixelCount: 100
            ).pasteboardItem(for: image)
            Issue.record("Expected unsafe ordinary screenshot encoding to be rejected")
        } catch BrowserScreenshotError.captureAreaTooLarge {
            // Expected: ordinary screenshots stay native or fail explicitly.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func screenshotPresentationSeparatesHostingFromSynchronization() {
        let onscreen = BrowserScreenshotPresentation.onscreen
        #expect(!onscreen.usesOffscreenRenderHost)
        #expect(BrowserScreenshotPresentation.offscreen.usesOffscreenRenderHost)
        #expect(
            onscreen.waitsForAnimationFrame(isRetry: false)
        )
        #expect(
            !BrowserScreenshotPresentation.offscreen
                .waitsForAnimationFrame(isRetry: false)
        )
        #expect(
            BrowserScreenshotPresentation.offscreen
                .waitsForAnimationFrame(isRetry: true)
        )
        #expect(
            BrowserScreenshotPresentation.resolve(
                isVisibleInUI: true,
                isAttachedToWindow: true,
                isHiddenOrHasHiddenAncestor: false,
                boundsSize: NSSize(width: 1600, height: 1200)
            ) == onscreen
        )
        #expect(
            BrowserScreenshotPresentation.resolve(
                isVisibleInUI: true,
                isAttachedToWindow: true,
                isHiddenOrHasHiddenAncestor: true,
                boundsSize: NSSize(width: 1600, height: 1200)
            ) == .offscreen
        )
        #expect(
            BrowserScreenshotPresentation.resolve(
                isVisibleInUI: true,
                isAttachedToWindow: false,
                isHiddenOrHasHiddenAncestor: false,
                boundsSize: NSSize(width: 1600, height: 1200)
            ) == .offscreen
        )
    }

    @Test
    func verifiedCaptureBudgetCoversRetriesAndSocketDelivery() {
        #expect(BrowserScreenshotCaptureService.defaultMaximumAttempts == 2)
        #expect(BrowserScreenshotCaptureService.automationLeaseTimeout == 34)
        #expect(
            BrowserScreenshotCaptureService.socketResponseTimeout
                > BrowserScreenshotCaptureService.automationLeaseTimeout
        )
    }

    @Test
    func screenshotTimingBudgetNestsEveryResponseDeadline() {
        let budget = BrowserScreenshotTimingBudget(
            maximumAttempts: 3,
            expectedURLAllowance: 2,
            preparationJavaScriptAllowance: 3,
            leaseOverheadAllowance: 10,
            probeCollectionAllowance: 5,
            synchronizationAllowance: 4,
            snapshotCompletionAllowance: 6,
            socketDeliveryAllowance: 7,
            livenessProbeAllowance: 8,
            clientDeliveryAllowance: 9
        )

        #expect(budget.captureLeaseTimeout == 75)
        #expect(budget.socketResponseTimeout == 82)
        #expect(budget.clientResponseTimeout == 99)
    }

    @Test
    func continuationGateDeliversEarlyCancellationAndRejectsReuse() async {
        let gate = BrowserScreenshotContinuationGate<Void>()
        #expect(gate.finish(.failure(CancellationError())))

        await #expect(throws: CancellationError.self) {
            let _: Void = try await withCheckedThrowingContinuation { continuation in
                #expect(!gate.install(continuation))
            }
        }
        await #expect(throws: CancellationError.self) {
            let _: Void = try await withCheckedThrowingContinuation { continuation in
                #expect(!gate.install(continuation))
            }
        }
        #expect(!gate.finish(.success(())))
    }

    @Test
    func renderLeaseCompletesOnlyAfterCancelledOperationStops() async throws {
        let operationStarted = BrowserScreenshotContinuationGate<Void>()
        let operationCancelled = BrowserScreenshotContinuationGate<Void>()
        let leaseCompleted = BrowserScreenshotContinuationGate<Void>()
        let startedTask = Task { @MainActor in
            try await withCheckedThrowingContinuation { continuation in
                operationStarted.install(continuation)
            }
        }
        let cancelledTask = Task { @MainActor in
            try await withCheckedThrowingContinuation { continuation in
                operationCancelled.install(continuation)
            }
        }
        let completedTask = Task { @MainActor in
            try await withCheckedThrowingContinuation { continuation in
                leaseCompleted.install(continuation)
            }
        }
        var releaseOperation: CheckedContinuation<Void, Never>?
        var didTeardown = false
        var completionResult: Result<Void, Error>?
        let operationTask = Task { @MainActor in
            operationStarted.finish(.success(()))
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    releaseOperation = continuation
                }
            } onCancel: {
                Task { @MainActor in
                    operationCancelled.finish(.success(()))
                }
            }
        }
        let lease = BrowserScreenshotRenderLease<Void>(
            teardown: {
                didTeardown = true
            },
            completion: { result in
                completionResult = result
                leaseCompleted.finish(.success(()))
            }
        )
        lease.installOperationTask(operationTask)

        try await startedTask.value
        #expect(lease.finish(.failure(BrowserScreenshotError.automationTimedOut)))
        try await cancelledTask.value
        #expect(!didTeardown)

        let continuation = try #require(releaseOperation)
        releaseOperation = nil
        continuation.resume()
        try await completedTask.value

        #expect(didTeardown)
        guard case .failure(let error as BrowserScreenshotError) = completionResult,
              case .automationTimedOut = error else {
            Issue.record("Expected the render lease to complete with automationTimedOut")
            return
        }
    }

    @Test
    func snapshotRequestCancellationResumesExactlyOnce() async throws {
        var snapshotCompletion: (@MainActor (NSImage?, Error?) -> Void)?
        let request = BrowserScreenshotSnapshotRequest(
            renderer: nil,
            timeout: 60,
            startSnapshot: { snapshotCompletion = $0 }
        )
        let task = Task { @MainActor in
            try await request.capture()
        }
        for _ in 0..<100 where snapshotCompletion == nil {
            await Task.yield()
        }
        let completeSnapshot = try #require(snapshotCompletion)

        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        let lateImage = try makeBlankBitmapImage(width: 10, height: 10)
        completeSnapshot(lateImage, nil)
        completeSnapshot(lateImage, nil)
    }

    @Test
    func snapshotRequestDeadlineBoundsMissingWebKitCallback() async {
        let request = BrowserScreenshotSnapshotRequest(
            renderer: nil,
            timeout: 0,
            startSnapshot: { _ in }
        )

        do {
            _ = try await request.capture()
            Issue.record("Expected the snapshot deadline to fail")
        } catch BrowserScreenshotError.automationTimedOut {
            // Expected: one stalled snapshot cannot consume the entire retry lease.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func animationFrameCancellationResumesExactlyOnce() async throws {
        var frameCompletion: (@MainActor (Error?) -> Void)?
        let waiter = BrowserScreenshotAnimationFrameWaiter(
            timeout: 60,
            startFrame: { _, completion in frameCompletion = completion }
        )
        let task = Task { @MainActor in
            try await waiter.wait(script: "return true;")
        }
        for _ in 0..<100 where frameCompletion == nil {
            await Task.yield()
        }
        let completeFrame = try #require(frameCompletion)

        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        completeFrame(nil)
        completeFrame(nil)
    }

    @Test
    func animationFrameDeadlineReportsScreenshotTimeout() async {
        let waiter = BrowserScreenshotAnimationFrameWaiter(
            timeout: 0,
            startFrame: { _, _ in }
        )

        do {
            try await waiter.wait(script: "return true;")
            Issue.record("Expected the animation-frame deadline to fail")
        } catch BrowserScreenshotError.automationTimedOut {
            // Expected: do not misreport a stalled compositor as a pixel mismatch.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func javaScriptRequestCancellationResumesExactlyOnce() async throws {
        var evaluationCompletion: (
            @MainActor (Result<Any?, Error>) -> Void
        )?
        let request = BrowserScreenshotJavaScriptRequest(
            timeout: 60,
            startEvaluation: { _, completion in
                evaluationCompletion = completion
            }
        )
        let task = Task { @MainActor in
            try await request.evaluate(script: "return true;")
        }
        for _ in 0..<100 where evaluationCompletion == nil {
            await Task.yield()
        }
        let completeEvaluation = try #require(evaluationCompletion)

        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        completeEvaluation(.success(true))
        completeEvaluation(.failure(NSError(domain: "late", code: 1)))
    }

    @Test
    func javaScriptRequestDeadlineBoundsMissingWebKitCallback() async {
        let request = BrowserScreenshotJavaScriptRequest(
            timeout: 0,
            startEvaluation: { _, _ in }
        )

        do {
            _ = try await request.evaluate(script: "return true;")
            Issue.record("Expected the JavaScript deadline to fail")
        } catch BrowserScreenshotError.automationTimedOut {
            // Expected: the capture owner receives an actionable timeout signal.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func screenshotCaptureFailurePreservesWireErrorCodes() {
        let mismatch = BrowserScreenshotError.renderedContentMismatch(
            rect: NSRect(x: 1, y: 2, width: 3, height: 4),
            attempts: 2,
            mismatchCount: 2
        )
        let cases: [
            (error: Error, expectedCode: String?, expectedTimedOut: Bool)
        ] = [
            (BrowserScreenshotError.automationTimedOut, nil, true),
            (BrowserScreenshotError.captureInProgress, "timeout", false),
            (mismatch, "screenshot_mismatch", false),
            (BrowserScreenshotError.captureAreaTooLarge, "internal_error", false),
            (NSError(domain: "test", code: 1), "internal_error", false),
        ]

        for item in cases {
            let result = BrowserAutomationSnapshotResult.captureFailure(item.error)
            switch result {
            case .success:
                Issue.record("Capture failure unexpectedly produced image data")
            case .failure(let code, let message):
                #expect(!item.expectedTimedOut)
                #expect(code == item.expectedCode)
                #expect(!message.isEmpty)
            case .timedOut(let message):
                #expect(item.expectedTimedOut)
                #expect(item.expectedCode == nil)
                #expect(message == item.error.localizedDescription)
            }
        }
    }

    @Test
    func verifiedCaptureRetriesAFrameWithMultipleBlankTextProbes() async throws {
        var captureCount = 0
        var synchronizationRetries: [Bool] = []
        let probes = textProbeSet()
        let image = try makeBlankBitmapImage(width: 100, height: 100)
        let service = BrowserScreenshotCaptureService(
            maximumAttempts: 3,
            synchronize: {
                synchronizationRetries.append($0)
                return .completed
            },
            collectProbes: { probes },
            snapshot: {
                captureCount += 1
                return image
            },
            makePixelSource: { _ in
                if captureCount == 1 {
                    return SolidPixelSource(
                        pixelSize: probes.viewportSize,
                        color: .black
                    )
                }
                return TextPaintPixelSource(
                    pixelSize: probes.viewportSize,
                    textRects: probes.probes.map(\.rect)
                )
            }
        )

        _ = try await service.capture()

        #expect(captureCount == 2)
        #expect(synchronizationRetries == [false, true])
    }

    @Test
    func verifiedCaptureSynchronizesAfterPreSnapshotDOMInspection() async throws {
        var events: [String] = []
        let image = try makeBlankBitmapImage(width: 100, height: 100)
        let service = BrowserScreenshotCaptureService(
            maximumAttempts: 1,
            synchronize: { _ in
                events.append("synchronize")
                return .completed
            },
            collectProbes: {
                events.append("collect")
                return nil
            },
            snapshot: {
                events.append("snapshot")
                return image
            },
            makePixelSource: { _ in nil }
        )

        _ = try await service.capture()

        #expect(events == ["collect", "synchronize", "snapshot", "collect"])
    }

    @Test
    func verifiedCaptureDoesNotMisreportSynchronizationTimeoutAsPixelMismatch() async {
        var captureCount = 0
        let probes = textProbeSet()
        let service = BrowserScreenshotCaptureService(
            synchronize: { _ in .unconfirmed },
            collectProbes: { probes },
            snapshot: {
                captureCount += 1
                return try self.makeBlankBitmapImage(width: 100, height: 100)
            },
            makePixelSource: { _ in
                SolidPixelSource(pixelSize: probes.viewportSize, color: .black)
            }
        )

        do {
            _ = try await service.capture()
            Issue.record("Expected the synchronization timeout")
        } catch BrowserScreenshotError.automationTimedOut {
            // Expected: persistent disagreement after an unconfirmed barrier is a timeout.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(captureCount == 2)
    }

    @Test
    func verifiedCaptureAcceptsPaintedFrameWhenSynchronizationTimesOut() async throws {
        var captureCount = 0
        let probes = textProbeSet()
        let service = BrowserScreenshotCaptureService(
            synchronize: { _ in .unconfirmed },
            collectProbes: { probes },
            snapshot: {
                captureCount += 1
                return try self.makeBlankBitmapImage(width: 100, height: 100)
            },
            makePixelSource: { _ in
                TextPaintPixelSource(
                    pixelSize: probes.viewportSize,
                    textRects: probes.probes.map(\.rect)
                )
            }
        )

        _ = try await service.capture()

        #expect(captureCount == 1)
    }

    @Test
    func verifiedCaptureFailsLoudlyWithoutLeakingDOMText() async throws {
        var captureCount = 0
        let sensitiveText = "Account 8675309 balance $1234"
        let probes = textProbeSet(firstText: sensitiveText)
        let image = try makeBlankBitmapImage(width: 100, height: 100)
        let service = BrowserScreenshotCaptureService(
            maximumAttempts: 3,
            synchronize: { _ in .completed },
            collectProbes: { probes },
            snapshot: {
                captureCount += 1
                return image
            },
            makePixelSource: { _ in
                SolidPixelSource(pixelSize: probes.viewportSize, color: .black)
            }
        )

        do {
            _ = try await service.capture()
            Issue.record("Expected a rendered-content mismatch")
        } catch let error as BrowserScreenshotError {
            guard case let .renderedContentMismatch(rect, attempts, mismatchCount) = error else {
                Issue.record("Unexpected screenshot error: \(error)")
                return
            }
            #expect(rect == probes.probes[0].rect)
            #expect(attempts == 3)
            #expect(mismatchCount == 2)
            #expect(!error.localizedDescription.contains(sensitiveText))
            #expect(!String(describing: error).contains(sensitiveText))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(captureCount == 3)
    }

    @Test
    func verifiedCaptureDefaultsToOneRetry() async throws {
        var captureCount = 0
        let probes = textProbeSet()
        let image = try makeBlankBitmapImage(width: 100, height: 100)
        let service = BrowserScreenshotCaptureService(
            synchronize: { _ in .completed },
            collectProbes: { probes },
            snapshot: {
                captureCount += 1
                return image
            },
            makePixelSource: { _ in
                SolidPixelSource(pixelSize: probes.viewportSize, color: .black)
            }
        )

        do {
            _ = try await service.capture()
            Issue.record("Expected a rendered-content mismatch")
        } catch let BrowserScreenshotError.renderedContentMismatch(
            _,
            attempts,
            _
        ) {
            #expect(attempts == 2)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(captureCount == 2)
    }

    @Test
    func verifiedCaptureAcceptsPagesWithoutTextProbes() async throws {
        var captureCount = 0
        let image = try makeBlankBitmapImage(width: 100, height: 100)
        let service = BrowserScreenshotCaptureService(
            maximumAttempts: 3,
            synchronize: { _ in .completed },
            collectProbes: {
                BrowserScreenshotProbeSet(
                    viewportSize: NSSize(width: 100, height: 100),
                    probes: []
                )
            },
            snapshot: {
                captureCount += 1
                return image
            },
            makePixelSource: { _ in
                SolidPixelSource(
                    pixelSize: NSSize(width: 100, height: 100),
                    color: .black
                )
            }
        )

        _ = try await service.capture()

        #expect(captureCount == 1)
    }

    @Test
    func verifierTreatsOneDisagreeingProbeAsInconclusive() {
        let probes = textProbeSet()
        let oneProbe = BrowserScreenshotProbeSet(
            viewportSize: probes.viewportSize,
            probes: [probes.probes[0]]
        )
        let outcome = BrowserScreenshotFrameVerifier().verify(
            before: oneProbe,
            after: oneProbe,
            pixels: SolidPixelSource(
                pixelSize: probes.viewportSize,
                color: .black
            )
        )

        #expect(outcome == .accepted)
    }

    @Test
    func verifierAcceptsUniformPixelsThatDifferFromCSSBackground() {
        let probes = textProbeSet()
        let outcome = BrowserScreenshotFrameVerifier().verify(
            before: probes,
            after: probes,
            pixels: SolidPixelSource(
                pixelSize: probes.viewportSize,
                color: .white
            )
        )

        #expect(outcome == .accepted)
    }

    @Test
    func verifierRejectsUniformBlankMatchingCSSBackground() {
        let probes = textProbeSet()
        let outcome = BrowserScreenshotFrameVerifier().verify(
            before: probes,
            after: probes,
            pixels: SolidPixelSource(
                pixelSize: probes.viewportSize,
                color: .black
            )
        )

        #expect(outcome == .mismatch(probe: probes.probes[0], count: 2))
    }

    @Test
    func verifierRejectsUniformTransparentPixelsOverOpaqueDOMBackground() {
        let probes = textProbeSet()
        let outcome = BrowserScreenshotFrameVerifier().verify(
            before: probes,
            after: probes,
            pixels: SolidPixelSource(
                pixelSize: probes.viewportSize,
                color: BrowserScreenshotRGBA(
                    red: 0,
                    green: 0,
                    blue: 0,
                    alpha: 0
                )
            )
        )

        #expect(outcome == .mismatch(probe: probes.probes[0], count: 2))
    }

    @Test
    func verifierUsesBulkPixelSampling() {
        let probes = textProbeSet()
        let outcome = BrowserScreenshotFrameVerifier().verify(
            before: probes,
            after: probes,
            pixels: BulkOnlyPixelSource(pixelSize: probes.viewportSize)
        )

        #expect(outcome == .mismatch(probe: probes.probes[0], count: 2))
    }

    @Test
    func verifierAcceptsNonuniformViewportToPixelScaling() {
        let probes = textProbeSet()
        let outcome = BrowserScreenshotFrameVerifier().verify(
            before: probes,
            after: probes,
            pixels: SolidPixelSource(
                pixelSize: NSSize(width: 100, height: 50),
                color: .black
            )
        )

        #expect(outcome == .accepted)
    }

    @Test
    func verifierAcceptsTwoPixelScaleSkewAsInconclusive() {
        let probes = textProbeSet()
        let outcome = BrowserScreenshotFrameVerifier().verify(
            before: probes,
            after: probes,
            pixels: SolidPixelSource(
                pixelSize: NSSize(width: 100, height: 98),
                color: .black
            )
        )

        #expect(outcome == .accepted)
    }

    @Test
    func verifierAcceptsAOnePixelTextStroke() {
        let probes = textProbeSet()
        let outcome = BrowserScreenshotFrameVerifier().verify(
            before: probes,
            after: probes,
            pixels: ThinTextStrokePixelSource(
                pixelSize: probes.viewportSize,
                textRects: probes.probes.map(\.rect)
            )
        )

        #expect(outcome == .accepted)
    }

    @Test
    func verifierRequiresBlankEvidenceFromDistinctViewportCells() {
        let original = textProbeSet()
        let sameCellProbe = BrowserScreenshotProbe(
            identifier: "nearby-balance",
            text: "Available",
            rect: NSRect(x: 12, y: 14, width: 10, height: 12),
            foreground: .white,
            background: .black
        )
        let probes = BrowserScreenshotProbeSet(
            viewportSize: original.viewportSize,
            probes: [original.probes[0], sameCellProbe]
        )
        let outcome = BrowserScreenshotFrameVerifier().verify(
            before: probes,
            after: probes,
            pixels: SolidPixelSource(pixelSize: probes.viewportSize, color: .black)
        )

        #expect(outcome == .accepted)
    }

    @Test
    func verifierReportsEveryBlankProbe() {
        let original = textProbeSet()
        let nearby = BrowserScreenshotProbe(
            identifier: "nearby-balance",
            text: "Available",
            rect: NSRect(x: 12, y: 14, width: 10, height: 12),
            foreground: .white,
            background: .black
        )
        let third = BrowserScreenshotProbe(
            identifier: "secondary-action",
            text: "Withdraw",
            rect: NSRect(x: 30, y: 35, width: 12, height: 12),
            foreground: .white,
            background: .black
        )
        let probes = BrowserScreenshotProbeSet(
            viewportSize: original.viewportSize,
            probes: original.probes + [nearby, third]
        )
        let outcome = BrowserScreenshotFrameVerifier().verify(
            before: probes,
            after: probes,
            pixels: SolidPixelSource(pixelSize: probes.viewportSize, color: .black)
        )

        #expect(outcome == .mismatch(probe: probes.probes[0], count: 4))
    }

    @Test
    func verifierIgnoresTextThatMovesDuringCapture() {
        let before = textProbeSet()
        let after = BrowserScreenshotProbeSet(
            viewportSize: before.viewportSize,
            probes: before.probes.map {
                BrowserScreenshotProbe(
                    identifier: $0.identifier,
                    text: $0.text,
                    rect: $0.rect.offsetBy(dx: 3, dy: 0),
                    foreground: $0.foreground,
                    background: $0.background
                )
            }
        )
        let outcome = BrowserScreenshotFrameVerifier().verify(
            before: before,
            after: after,
            pixels: SolidPixelSource(
                pixelSize: before.viewportSize,
                color: .black
            )
        )

        #expect(outcome == .accepted)
    }

    @Test
    func bitmapPixelSourceUsesTopLeftCoordinates() throws {
        var pixels = Data()
        pixels.reserveCapacity(400)
        for row in 0..<10 {
            let color: [UInt8] = row < 5
                ? [0, 0, 255, 255]
                : [255, 0, 0, 255]
            for _ in 0..<10 {
                pixels.append(contentsOf: color)
            }
        }
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        let cgImage = try #require(CGImage(
            width: 10,
            height: 10,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 40,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )

        let source = try #require(BrowserScreenshotBitmapPixelSource(image: image))
        let top = try #require(source.color(at: NSPoint(x: 5, y: 1)))
        let bottom = try #require(source.color(at: NSPoint(x: 5, y: 8)))

        #expect(top.blue > 0.9)
        #expect(top.red < 0.1)
        #expect(bottom.red > 0.9)
        #expect(bottom.blue < 0.1)
    }

    @Test
    func bitmapPixelSourceRejectsFractionalSampleRectangles() throws {
        let image = try makeBlankBitmapImage(width: 10, height: 10)
        let source = try #require(BrowserScreenshotBitmapPixelSource(image: image))

        #expect(source.colors(
            in: NSRect(x: 0.5, y: 0, width: 1, height: 1),
            stride: 1
        ) == nil)
    }

    @Test
    func bitmapPixelSourceReadsAlphaFirstPackedBytes() throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [.alphaFirst],
            bytesPerRow: 4,
            bitsPerPixel: 32
        ))
        let bytes = try #require(bitmap.bitmapData)
        bytes[0] = 255
        bytes[1] = 255
        bytes[2] = 0
        bytes[3] = 0
        bitmap.size = NSSize(width: 1, height: 1)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)

        let source = try #require(BrowserScreenshotBitmapPixelSource(image: image))
        let color = try #require(source.color(at: NSPoint(x: 0.5, y: 0.5)))

        #expect(color.red > 0.9)
        #expect(color.green < 0.1)
        #expect(color.blue < 0.1)
        #expect(color.alpha > 0.9)
    }

    @Test
    func bitmapPixelSourceSamplesHigherPrecisionRepresentation() throws {
        let supported = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 10,
            pixelsHigh: 10,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let unsupported = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 20,
            pixelsHigh: 20,
            bitsPerSample: 16,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        supported.size = NSSize(width: 10, height: 10)
        unsupported.size = NSSize(width: 20, height: 20)
        let image = NSImage(size: unsupported.size)
        image.addRepresentation(supported)
        image.addRepresentation(unsupported)

        let source = try #require(BrowserScreenshotBitmapPixelSource(image: image))

        #expect(source.pixelSize.width > 0)
        #expect(source.pixelSize.height > 0)
        #expect(source.color(at: NSPoint(x: 0.5, y: 0.5)) != nil)
    }

    @Test
    func bitmapPixelSourceReturnsStraightColorFromPremultipliedBGRA() throws {
        let pixels = Data([
            0, 0, 128, 128,
            0, 0, 128, 128,
            0, 0, 128, 128,
            0, 0, 128, 128,
        ])
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        let cgImage = try #require(CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )

        let source = try #require(BrowserScreenshotBitmapPixelSource(image: image))
        let color = try #require(source.color(at: NSPoint(x: 0.5, y: 0.5)))

        #expect(color.red > 0.9)
        #expect(color.green < 0.1)
        #expect(color.blue < 0.1)
        #expect(color.alpha > 0.45)
        #expect(color.alpha < 0.55)
    }

    @Test
    func bitmapPixelSourceConvertsDisplayP3ToSRGB() throws {
        let sourceBitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: sourceBitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        let bitmap = try #require(sourceBitmap.converting(
            to: .displayP3,
            renderingIntent: .default
        ))
        bitmap.size = NSSize(width: 2, height: 2)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)

        let source = try #require(BrowserScreenshotBitmapPixelSource(image: image))
        let color = try #require(source.color(at: NSPoint(x: 0.5, y: 0.5)))

        #expect(color.red > 0.9)
        #expect(color.green < 0.1)
        #expect(color.blue < 0.1)
    }

    @Test
    func domProbeCollectorCompositesNestedSolidBackgrounds() async throws {
        let probes = try await collectDOMProbes(
            html: """
            <!doctype html>
            <style>
              html, body { margin: 0; width: 100%; height: 100%; background: rgb(0, 0, 0); }
              #surface {
                position: absolute;
                inset: 0;
                background: rgba(255, 255, 255, 0.2);
              }
              p {
                margin: 0;
                position: absolute;
                left: 40px;
                top: 40px;
                color: rgb(255, 255, 255);
                font: 20px sans-serif;
              }
            </style>
            <div id="surface"><p>MMMM</p></div>
            """
        )
        let probe = try #require(probes.probes.first)

        #expect(abs(probe.background.red - 0.2) < 0.01)
        #expect(abs(probe.background.green - 0.2) < 0.01)
        #expect(abs(probe.background.blue - 0.2) < 0.01)
        #expect(probe.foreground.red > 0.99)
    }

    @Test
    func domProbeCollectorSupportsCJKAndLowercaseText() async throws {
        let cjk = try await collectDOMProbes(
            html: """
            <!doctype html>
            <style>
              html, body { margin: 0; background: black; }
              p { color: white; font: 20px sans-serif; }
            </style>
            <p>残高を確認</p>
            """
        )
        let lowercase = try await collectDOMProbes(
            html: """
            <!doctype html>
            <style>
              html, body { margin: 0; background: black; }
              p { color: white; font: 20px sans-serif; }
            </style>
            <p>hello world</p>
            """
        )

        #expect(cjk.probes.first?.text == "残高を確認")
        #expect(lowercase.probes.first?.text == "hello world")
    }

    @Test
    func domProbeCollectorDoesNotRejectComplexDOMByElementCount() async throws {
        let filler = String(repeating: "<span></span>", count: 2_001)
        let probes = try await collectDOMProbes(
            html: """
            <!doctype html>
            <style>
              html, body { margin: 0; background: black; }
              p { color: white; font: 20px sans-serif; }
            </style>
            <p>MMMM</p>
            \(filler)
            """
        )

        #expect(probes.probes.first?.text == "MMMM")
    }

    @Test
    func domProbeCollectorRejectsFullyClippedTextAndEmptyPages() async throws {
        let clipped = try await collectDOMProbes(
            html: """
            <!doctype html>
            <style>
              html, body { margin: 0; background: black; }
              #clip { width: 1px; height: 1px; overflow: hidden; }
              span { color: white; font: 20px sans-serif; }
            </style>
            <div id="clip"><span>MMMM</span></div>
            """
        )
        let imageOnly = try await collectDOMProbes(
            html: """
            <!doctype html>
            <style>html, body { margin: 0; background: black; }</style>
            <canvas width="100" height="100"></canvas>
            """
        )

        #expect(clipped.probes.isEmpty)
        #expect(imageOnly.probes.isEmpty)
    }

    @Test
    func domProbeCollectorSkipsPaintedPointerEventsNoneOverlay() async throws {
        let probes = try await collectDOMProbes(
            html: """
            <!doctype html>
            <style>
              html, body { margin: 0; width: 100%; height: 100%; background: white; }
              p {
                margin: 0;
                position: absolute;
                color: black;
                font: 20px sans-serif;
              }
              #first { left: 20px; top: 20px; }
              #second { right: 20px; bottom: 20px; }
              #overlay {
                position: fixed;
                inset: 0;
                z-index: 10;
                pointer-events: none !important;
                background: white;
              }
            </style>
            <p id="first">MMMM</p>
            <p id="second">WWWW</p>
            <div id="overlay"></div>
            """
        )
        #expect(probes.probes.isEmpty)
    }

    @Test
    func domProbeCollectorSkipsPendingFontsAndMaskedText() async throws {
        let pendingFontWebView = try await loadDOMWebView(
            html: """
            <!doctype html>
            <style>
              html, body { margin: 0; background: black; }
              p { color: white; font: 20px sans-serif; }
            </style>
            <p>MMMM</p>
            """,
            configuration: WKWebViewConfiguration()
        )
        pendingFontWebView.evaluateJavaScript(
            """
            (() => {
              Object.defineProperty(document, "fonts", {
                value: { status: "loading" },
                configurable: true
              });
              return document.fonts.status;
            })();
            """,
            in: nil,
            in: .defaultClient
        )
        let pendingFontValue = await BrowserScreenshotDOMProbeCollector(
            webView: pendingFontWebView
        ).collect()
        let pendingFont = try #require(pendingFontValue)
        let masked = try await collectDOMProbes(
            html: """
            <!doctype html>
            <style>
              html, body { margin: 0; background: black; }
              #masked {
                -webkit-mask-image: linear-gradient(transparent, transparent);
                mask-image: linear-gradient(transparent, transparent);
              }
              p { color: white; font: 20px sans-serif; }
            </style>
            <div id="masked"><p>MMMM</p></div>
            """
        )

        #expect(pendingFont.probes.isEmpty)
        #expect(masked.probes.isEmpty)
    }

    private func collectDOMProbes(
        html: String
    ) async throws -> BrowserScreenshotProbeSet {
        try await collectDOMProbes(
            html: html,
            configuration: WKWebViewConfiguration()
        )
    }

    private func collectDOMProbes(
        html: String,
        configuration: WKWebViewConfiguration
    ) async throws -> BrowserScreenshotProbeSet {
        let webView = try await loadDOMWebView(
            html: html,
            configuration: configuration
        )
        let collected = await BrowserScreenshotDOMProbeCollector(webView: webView).collect()
        return try #require(collected)
    }

    private func loadDOMWebView(
        html: String,
        configuration: WKWebViewConfiguration
    ) async throws -> WKWebView {
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300),
            configuration: configuration
        )
        let navigation = BrowserScreenshotTestNavigation()
        try await navigation.load(html: html, in: webView)
        return webView
    }

    private func textProbeSet(
        firstText: String = "Balance"
    ) -> BrowserScreenshotProbeSet {
        BrowserScreenshotProbeSet(
            viewportSize: NSSize(width: 100, height: 100),
            probes: [
                .init(
                    identifier: "balance",
                    text: firstText,
                    rect: NSRect(x: 10, y: 10, width: 10, height: 12),
                    foreground: .white,
                    background: .black
                ),
                .init(
                    identifier: "primary-action",
                    text: "Add funds",
                    rect: NSRect(x: 60, y: 60, width: 10, height: 12),
                    foreground: .white,
                    background: .black
                ),
            ]
        )
    }

    private struct SolidPixelSource: PointSamplingPixelSource {
        let pixelSize: NSSize
        let color: BrowserScreenshotRGBA

        func testColor(at point: NSPoint) -> BrowserScreenshotRGBA? {
            guard NSRect(origin: .zero, size: pixelSize).contains(point) else {
                return nil
            }
            return color
        }
    }

    private struct BulkOnlyPixelSource: BrowserScreenshotPixelSource {
        let pixelSize: NSSize

        func colors(
            in rect: NSRect,
            stride: Int
        ) -> [BrowserScreenshotRGBA]? {
            [.black]
        }
    }

    private struct TextPaintPixelSource: PointSamplingPixelSource {
        let pixelSize: NSSize
        let textRects: [NSRect]

        func testColor(at point: NSPoint) -> BrowserScreenshotRGBA? {
            guard NSRect(origin: .zero, size: pixelSize).contains(point) else {
                return nil
            }
            for rect in textRects where rect.contains(point) {
                let stroke = NSRect(
                    x: rect.midX - 1,
                    y: rect.minY + 1,
                    width: 2,
                    height: max(1, rect.height - 2)
                )
                if stroke.contains(point) {
                    return .white
                }
            }
            return .black
        }
    }

    private struct ThinTextStrokePixelSource: PointSamplingPixelSource {
        let pixelSize: NSSize
        let textRects: [NSRect]

        func testColor(at point: NSPoint) -> BrowserScreenshotRGBA? {
            guard NSRect(origin: .zero, size: pixelSize).contains(point) else {
                return nil
            }
            for rect in textRects where rect.contains(point) {
                let strokeX = Int(rect.midX.rounded(.down))
                if Int(point.x.rounded(.down)) == strokeX {
                    return .white
                }
            }
            return .black
        }
    }

    /// Makes the legacy `NSImage.lockFocus()` path deterministically rasterize
    /// at Retina scale while forwarding unrelated threads to AppKit unchanged.
    private func withImageFocusBackingScale<T>(
        _ scale: Int,
        operation: () throws -> T
    ) throws -> T {
        guard Self.imageFocusOverrideInstalled else {
            Issue.record("Could not install the controlled image-focus context")
            return try operation()
        }
        Thread.current.threadDictionary[Self.imageFocusBackingScaleKey] = scale
        defer {
            Thread.current.threadDictionary.removeObject(
                forKey: Self.imageFocusBackingScaleKey
            )
        }

        return try operation()
    }

    private func makePatternedBitmapImage() throws -> NSImage {
        let width = 400
        let height = 300
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.magenta.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        testRed.setFill()
        NSRect(x: 100, y: 50, width: 100, height: 50).fill()
        testGreen.setFill()
        NSRect(x: 200, y: 50, width: 100, height: 50).fill()
        testBlue.setFill()
        NSRect(x: 100, y: 100, width: 100, height: 50).fill()
        testYellow.setFill()
        NSRect(x: 200, y: 100, width: 100, height: 50).fill()
        NSGraphicsContext.restoreGraphicsState()

        let size = NSSize(width: width, height: height)
        bitmap.size = size
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    private func makeBlankBitmapImage(width: Int, height: Int) throws -> NSImage {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = NSSize(width: width, height: height)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return image
    }

    private var testRed: NSColor { NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1) }
    private var testGreen: NSColor { NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1) }
    private var testBlue: NSColor { NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1) }
    private var testYellow: NSColor { NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1) }

    private func expectColor(
        _ expected: NSColor,
        atX x: Int,
        y: Int,
        in bitmap: NSBitmapImageRep
    ) throws {
        let actualRGB = try #require(
            bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        )
        let expectedRGB = try #require(expected.usingColorSpace(.sRGB))
        // AppKit and ImageIO attach different display-independent profiles to
        // bitmap-backed images. Keep this strict enough to reject a swapped
        // quadrant while allowing their expected color-space conversion.
        let tolerance = 0.25

        #expect(abs(actualRGB.redComponent - expectedRGB.redComponent) < tolerance)
        #expect(abs(actualRGB.greenComponent - expectedRGB.greenComponent) < tolerance)
        #expect(abs(actualRGB.blueComponent - expectedRGB.blueComponent) < tolerance)
        #expect(abs(actualRGB.alphaComponent - expectedRGB.alphaComponent) < tolerance)
    }
}

private protocol PointSamplingPixelSource: BrowserScreenshotPixelSource {
    func testColor(at point: NSPoint) -> BrowserScreenshotRGBA?
}

private extension PointSamplingPixelSource {
    func colors(
        in rect: NSRect,
        stride: Int
    ) -> [BrowserScreenshotRGBA]? {
        let minX = Int(rect.minX.rounded(.down))
        let minY = Int(rect.minY.rounded(.down))
        let maxX = Int(rect.maxX.rounded(.up)) - 1
        let maxY = Int(rect.maxY.rounded(.up)) - 1
        guard stride > 0, minX <= maxX, minY <= maxY else { return nil }

        var result: [BrowserScreenshotRGBA] = []
        for y in Swift.stride(from: minY, through: maxY, by: stride) {
            for x in Swift.stride(from: minX, through: maxX, by: stride) {
                guard let color = testColor(
                    at: NSPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                ) else {
                    return nil
                }
                result.append(color)
            }
        }
        return result
    }
}

@MainActor
private final class BrowserScreenshotTestNavigation: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTimer: Timer?

    func load(html: String, in webView: WKWebView) async throws {
        webView.navigationDelegate = self
        defer { webView.navigationDelegate = nil }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let timer = Timer(timeInterval: 5, repeats: false) { [weak self, weak webView] _ in
                Task { @MainActor [weak self, weak webView] in
                    webView?.stopLoading()
                    self?.finish(.failure(NSError(
                        domain: "BrowserScreenshotCropTests.Navigation",
                        code: 1
                    )))
                }
            }
            timeoutTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        continuation.resume(with: result)
    }
}
