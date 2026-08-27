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
    @Test func reconcilesDrawableAfterFullSizeUpdateRunsBeforeMetalLayerRealizes() throws {
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
        let initialDrawableSize = surfaceView.convertToBacking(initialFrame).size
        _ = surfaceView.forceRefreshSurface()
        #expect(surfaceView.layer is CAMetalLayer)
        #expect(surfaceView.debugLastDrawableSizeForTesting() == initialDrawableSize)
        drainDeferredSurfaceSizeRetry(on: surfaceView)
        #expect(!surfaceView.debugDeferredSurfaceSizeRetryQueuedForTesting())

        let nonMetalLayer = CALayer()
        nonMetalLayer.contentsScale = window.backingScaleFactor
        surfaceView.layer = nonMetalLayer
        #expect(!surfaceView.debugDeferredSurfaceSizeRetryQueuedForTesting())

        let targetFrame = NSRect(origin: .zero, size: targetSize)
        window.setFrame(targetFrame, display: false)
        hostedView.frame = targetFrame
        surfaceView.frame = targetFrame
        #expect(surfaceView.bounds.size == targetSize)

        let expectedDrawableSize = surfaceView.convertToBacking(targetFrame).size
        #expect(expectedDrawableSize.width > 0)
        #expect(expectedDrawableSize.height > 0)
        #expect(expectedDrawableSize != initialDrawableSize)

        _ = surfaceView.debugUpdateSurfaceSizeForTesting(targetSize)

        #expect(surfaceView.debugLastDrawableSizeForTesting() == initialDrawableSize)
        #expect(surfaceView.debugDeferredSurfaceSizeRetryQueuedForTesting())

        let realizedLayer = try #require(surfaceView.makeBackingLayer() as? CAMetalLayer)
        realizedLayer.contentsScale = window.backingScaleFactor
        realizedLayer.masksToBounds = true
        realizedLayer.drawableSize = initialDrawableSize
        surfaceView.layer = realizedLayer

        let deadline = Date().addingTimeInterval(0.5)
        while realizedLayer.drawableSize != expectedDrawableSize && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
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

    private func drainDeferredSurfaceSizeRetry(on surfaceView: GhosttyNSView) {
        let deadline = Date().addingTimeInterval(0.5)
        while surfaceView.debugDeferredSurfaceSizeRetryQueuedForTesting() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
