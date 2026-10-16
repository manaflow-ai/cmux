import AppKit
import QuartzCore
import Testing
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct GhosttyDrawableSizeRetryTests {
    @Test func reconcilesDrawableAfterFullSizeUpdateRunsBeforeMetalLayerRealizes() async throws {
        _ = NSApplication.shared

        let initialSize = CGSize(width: 800, height: 600)
        let targetSize = CGSize(width: 1296, height: 893)
        let initialFrame = NSRect(origin: .zero, size: initialSize)
        let terminalSurface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = terminalSurface.hostedView
        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.close()
        }

        let contentView = try #require(window.contentView)
        hostedView.frame = initialFrame
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        _ = hostedView.reconcileGeometryNow()

        let surfaceView = try #require(findGhosttyNSView(in: hostedView))
        _ = surfaceView.forceRefreshSurface()
        let initialDrawableSize = surfaceView.convertToBacking(surfaceView.bounds).size
        #expect(surfaceView.layer is CAMetalLayer)
        #expect(surfaceView.debugLastDrawableSizeForTesting() == initialDrawableSize)
        await drainDeferredSurfaceSizeRetry(on: surfaceView)
        #expect(!surfaceView.debugDeferredSurfaceSizeRetryQueuedForTesting())

        let nonMetalLayer = CALayer()
        nonMetalLayer.contentsScale = window.backingScaleFactor
        surfaceView.layer = nonMetalLayer
        #expect(!surfaceView.debugDeferredSurfaceSizeRetryQueuedForTesting())

        let targetFrame = NSRect(origin: .zero, size: targetSize)
        window.setFrame(targetFrame, display: false)
        hostedView.frame = targetFrame
        _ = hostedView.reconcileGeometryNow()
        let targetViewportSize = surfaceView.bounds.size
        #expect(targetViewportSize.width <= targetSize.width)
        #expect(targetViewportSize.width > initialSize.width)

        let expectedDrawableSize = surfaceView.convertToBacking(surfaceView.bounds).size
        #expect(expectedDrawableSize.width > 0)
        #expect(expectedDrawableSize.height > 0)
        #expect(expectedDrawableSize != initialDrawableSize)

        _ = surfaceView.commitPaneGeometry(size: targetViewportSize, phase: .settled)

        #expect(surfaceView.debugLastDrawableSizeForTesting() == initialDrawableSize)
        #expect(surfaceView.debugDeferredSurfaceSizeRetryQueuedForTesting())

        let realizedLayer = try #require(surfaceView.makeBackingLayer() as? CAMetalLayer)
        realizedLayer.contentsScale = window.backingScaleFactor
        realizedLayer.masksToBounds = true
        realizedLayer.drawableSize = initialDrawableSize
        surfaceView.layer = realizedLayer

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while realizedLayer.drawableSize != expectedDrawableSize && ContinuousClock.now < deadline {
            await yieldMainQueue()
        }

        #expect(realizedLayer.drawableSize == expectedDrawableSize)
    }

    private func findGhosttyNSView(in view: NSView) -> GhosttyNSView? {
        if let view = view as? GhosttyNSView {
            return view
        }

        for subview in view.subviews {
            if let match = findGhosttyNSView(in: subview) {
                return match
            }
        }

        return nil
    }

    private func drainDeferredSurfaceSizeRetry(on surfaceView: GhosttyNSView) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while surfaceView.debugDeferredSurfaceSizeRetryQueuedForTesting() && ContinuousClock.now < deadline {
            await yieldMainQueue()
        }
    }

    private func yieldMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
