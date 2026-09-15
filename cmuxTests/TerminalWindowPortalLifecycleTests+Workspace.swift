import AppKit
import CmuxTerminal
import GhosttyKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalWindowPortalLifecycleTests {
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
