import AppKit
import QuartzCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct GhosttyDrawableSizeRetryTests {
    @Test func reconcilesDrawableAfterLayerRealizesFollowingNonMetalResize() throws {
        _ = NSApplication.shared

        let targetSize = CGSize(width: 1296, height: 893)
        let targetFrame = NSRect(origin: .zero, size: targetSize)
        let terminalSurface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = terminalSurface.hostedView
        let window = NSWindow(
            contentRect: targetFrame,
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
        hostedView.frame = targetFrame
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        _ = hostedView.reconcileGeometryNow()

        let surfaceView = try #require(findGhosttyNSView(in: hostedView))
        let expectedDrawableSize = surfaceView.convertToBacking(targetFrame).size
        #expect(expectedDrawableSize.width > 0)
        #expect(expectedDrawableSize.height > 0)

        let staleDrawableSize = CGSize(
            width: max(1, floor(expectedDrawableSize.width / 2)),
            height: max(1, floor(expectedDrawableSize.height / 2))
        )
        #expect(staleDrawableSize != expectedDrawableSize)

        let nonMetalLayer = CALayer()
        nonMetalLayer.contentsScale = window.backingScaleFactor
        surfaceView.layer = nonMetalLayer

        _ = surfaceView.forceRefreshSurface()

        let realizedLayer = GhosttyMetalLayer()
        realizedLayer.setSurfaceView(surfaceView)
        realizedLayer.contentsScale = window.backingScaleFactor
        realizedLayer.masksToBounds = true
        realizedLayer.drawableSize = staleDrawableSize
        surfaceView.layer = realizedLayer

        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

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
}
