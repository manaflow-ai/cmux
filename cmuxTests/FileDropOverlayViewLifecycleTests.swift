import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct FileDropOverlayViewLifecycleTests {
    private func makeOverlay() -> (NSWindow, FileDropOverlayView) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let overlay = FileDropOverlayView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
        window.contentView = overlay
        window.displayIfNeeded()
        return (window, overlay)
    }

    private func showHint(in overlay: FileDropOverlayView) {
        overlay.hintBadgeView.show(
            text: "Hold Shift to open as split",
            centeredIn: overlay.bounds,
            clippedTo: overlay.bounds
        )
    }

    private func close(_ window: NSWindow) {
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        window.orderOut(nil)
    }

    @Test
    func draggingExitHidesHint() {
        let (window, overlay) = makeOverlay()
        defer { close(window) }
        showHint(in: overlay)

        overlay.draggingExited(nil)

        #expect(overlay.hintBadgeView.isHidden)
    }

    @Test
    func windowResignationHidesHintImmediately() {
        let (window, overlay) = makeOverlay()
        defer { close(window) }
        showHint(in: overlay)

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)

        #expect(overlay.hintBadgeView.isHidden)
    }

    @Test
    func anotherKeyWindowHidesHintImmediately() {
        let (window, overlay) = makeOverlay()
        defer { close(window) }
        let otherWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { close(otherWindow) }
        showHint(in: overlay)

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: otherWindow)

        #expect(overlay.hintBadgeView.isHidden)
    }

    @Test
    func applicationDeactivationHidesHintImmediately() {
        let (window, overlay) = makeOverlay()
        defer { close(window) }
        showHint(in: overlay)

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)

        #expect(overlay.hintBadgeView.isHidden)
    }

}
