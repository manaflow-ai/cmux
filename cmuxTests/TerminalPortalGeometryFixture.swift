import AppKit
import CmuxTerminal
import Darwin
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
               geometry.phase == .settled, gridMatchesPTY(),
               portal.entriesByHostedId[hostedID]?.needsSettledCommit == false,
               width.map({ abs($0 - geometry.size.width) < 0.5 }) ?? true {
                return true
            }
            flushLayout()
        } while Date() < deadline
        return false
    }

    /// Read the actual terminal screen and kernel TTY, not just Ghostty's
    /// main-thread size cache, which can lead its asynchronous IO resize.
    private func gridMatchesPTY() -> Bool {
        guard let runtime = surface.surface,
              let name = surface.controllingTTYName() else { return false }
        let path = name.hasPrefix("/dev/") ? name : "/dev/\(name)"
        let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOCTTY)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var size = winsize()
        var grid = ghostty_surface_grid_metrics_s()
        guard ioctl(descriptor, TIOCGWINSZ, &size) == 0,
              ghostty_surface_grid_metrics(runtime, &grid) else { return false }
        let requested = ghostty_surface_size(runtime)
        return grid.columns > 1 && grid.rows > 1 &&
            grid.columns == size.ws_col && grid.rows == size.ws_row &&
            grid.columns == requested.columns && grid.rows == requested.rows
    }

    func close() {
        endResize()
        surface.releaseSurfaceForTesting()
        portal.tearDown()
        window.close()
        workspace.tearDown()
    }
}
