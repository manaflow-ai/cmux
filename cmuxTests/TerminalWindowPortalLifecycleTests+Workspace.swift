import AppKit
import CmuxTerminal
import GhosttyKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalWindowPortalLifecycleTests {
    func waitForPortalPresentation(
        _ surface: TerminalSurface,
        after baseline: GhosttySurfaceScrollView.DebugRenderStats
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !Task.isCancelled {
            let stats = surface.hostedView.debugRenderStats()
            // Embedded Ghostty can present through IOSurfaceLayer instead of
            // CAMetalLayer; its contents seed is the observable frame change.
            if stats.metalDrawableCount > baseline.metalDrawableCount ||
                (stats.layerContentsKey != "nil" && stats.presentCount > baseline.presentCount) { return true }
            guard ContinuousClock.now < deadline else { return false }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        return false
    }

    /// Wait for the queued portal commit and runtime creation without holding
    /// the main actor in a nested run loop.
    func waitForSettledPortalGeometry(_ surface: TerminalSurface, anchor: NSView) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !Task.isCancelled {
            let hosted = surface.hostedView
            let view = hosted.surfaceView
            let pixels = surface.debugCurrentPixelSize()
            let expected = view.expectedPixelSize(for: view.bounds.size)
            if surface.surface != nil, surface.committedPaneGeometry?.phase == .settled,
               surface.committedPaneGeometry?.size == view.bounds.size,
               hosted.frame.size == anchor.bounds.size, view.bounds.width > 1,
               pixels.width == UInt32(expected.width.rounded(.down)),
               pixels.height == UInt32(expected.height.rounded(.down)) { return true }
            guard ContinuousClock.now < deadline else { return false }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        return false
    }

    func layoutResizeTestWindow(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func waitForResizeTestGeometry(_ surface: TerminalSurface, anchor: NSView) -> Bool {
        waitUntil(timeout: 2) {
            let hosted = surface.hostedView
            let view = hosted.surfaceView
            let pixels = surface.debugCurrentPixelSize()
            let expected = view.expectedPixelSize(for: view.bounds.size)
            return hosted.isVisibleInUI && !hosted.isHidden &&
                hosted.frame.size == anchor.bounds.size &&
                view.bounds.width > 1 && view.bounds.height > 1 &&
                view.bounds.width <= hosted.bounds.width &&
                pixels.width == UInt32(expected.width.rounded(.down)) &&
                pixels.height == UInt32(expected.height.rounded(.down))
        }
    }

    func makeTrackedTerminalSurface() -> TerminalSurface {
        let workspace = testWorkspace ?? TerminalPortalTestWorkspace()
        testWorkspace = workspace
        let surface = TerminalSurface(
            tabId: workspace.id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        trackedSurfaces.append(surface)
        return surface
    }
}
