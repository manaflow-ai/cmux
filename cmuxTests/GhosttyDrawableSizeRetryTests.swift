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

    @Test func liveResizeEndBypassDoesNotPublishBeforePortalFinalPass() throws {
        _ = NSApplication.shared

        let initialSize = CGSize(width: 800, height: 600)
        let targetSize = CGSize(width: 1296, height: 893)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.close()
        }

        let terminalSurface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = terminalSurface.hostedView
        hostedView.frame = NSRect(origin: .zero, size: initialSize)
        window.contentView?.addSubview(hostedView)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        hostedView.layoutSubtreeIfNeeded()

        let surfaceView = try #require(findGhosttyNSView(in: hostedView))
        _ = surfaceView.forceRefreshSurface()
        let initialDrawableSize = surfaceView.debugLastDrawableSizeForTesting()
        surfaceView.setWindowLiveResizeActive(true)

        // GhosttyNSView.viewDidEndLiveResize uses bypass=true. The portal has
        // not committed its final pane frame yet, so this callback must keep
        // the last drawable epoch instead of publishing targetSize early.
        hostedView.frame.size = targetSize
        surfaceView.frame.size = targetSize
        surfaceView.viewDidEndLiveResize()

        #expect(
            surfaceView.debugLastDrawableSizeForTesting() == initialDrawableSize,
            "The end callback must not publish a stale size before the portal final pass"
        )
    }

    @Test func standaloneSurfaceUsesNativeWindowLiveResizeState() throws {
        _ = NSApplication.shared

        let window = LiveResizeProbeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.close()
        }

        let terminalSurface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = terminalSurface.hostedView
        hostedView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView?.addSubview(hostedView)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        hostedView.layoutSubtreeIfNeeded()

        let surfaceView = try #require(findGhosttyNSView(in: hostedView))
        _ = surfaceView.forceRefreshSurface()

        // This view is not owned by WindowTerminalPortal, so it has no portal
        // propagation flag. AppKit's native window state must still defer its
        // pixel-only resize work during the interactive resize.
        window.liveResizeActive = true
        #expect(surfaceView.debugIsWindowLiveResizeActiveForTesting())
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

private final class LiveResizeProbeWindow: NSWindow {
    var liveResizeActive = false

    override var inLiveResize: Bool { liveResizeActive }
}
