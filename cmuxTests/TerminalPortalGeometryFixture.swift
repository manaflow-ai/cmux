import AppKit
import CmuxTerminal
import GhosttyKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Owns only the window, process, and portal created by one geometry test.
@MainActor
final class TerminalPortalGeometryFixture {
    private let workspace = TerminalPortalTestWorkspace()
    let window: NSWindow
    let anchor: NSView
    let portal: WindowTerminalPortal
    let surface: TerminalSurface
    private var dividerResizeActive = false
    var hosted: GhosttySurfaceScrollView { surface.hostedView }
    var hostedID: ObjectIdentifier { ObjectIdentifier(hosted) }

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        anchor = NSView(frame: NSRect(x: 8, y: 8, width: 520, height: 280))
        window.contentView?.addSubview(anchor)
        portal = WindowTerminalPortal(window: window)
        surface = TerminalSurface(
            tabId: workspace.id, context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, workingDirectory: nil
        )
    }

    func bind(visible: Bool = true) {
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: visible)
    }

    func beginResize(native: Bool) {
        if native {
            portal.isWindowLiveResizeActiveOverrideForTesting = true
        } else {
            dividerResizeActive = true
            TerminalWindowPortalRegistry.beginInteractiveGeometryResize(in: window)
        }
    }

    func endResize() {
        portal.isWindowLiveResizeActiveOverrideForTesting = false
        if dividerResizeActive {
            dividerResizeActive = false
            TerminalWindowPortalRegistry.endInteractiveGeometryResize(in: window)
        }
        // A fixture owns a direct portal, outside the process-wide registry.
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
    }

    func flushLayout() {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }

    func waitForCommit(width: CGFloat? = nil) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if let geometry = surface.committedPaneGeometry,
               geometry.phase == .settled, surface.surface != nil,
               portal.entriesByHostedId[hostedID]?.needsSettledCommit == false,
               width.map({ abs($0 - geometry.size.width) < 0.5 }) ?? true {
                return true
            }
            flushLayout()
        } while Date() < deadline
        return false
    }

    func close() {
        endResize()
        surface.releaseSurfaceForTesting()
        portal.tearDown()
        window.close()
        workspace.tearDown()
    }
}
