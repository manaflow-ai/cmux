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
        return (window, overlay)
    }

    private func showHint(in overlay: FileDropOverlayView, sequenceNumber: Int = 1) {
        overlay.hintPresentation.begin(sequenceNumber: sequenceNumber)
        overlay.hintPresentation.show(
            sequenceNumber: sequenceNumber,
            text: "Hold Shift to open as split",
            centeredIn: overlay.bounds,
            clippedTo: overlay.bounds
        )
        #expect(!overlay.hintBadgeView.isHidden)
    }

    private func close(_ window: NSWindow) {
        window.close()
    }

    @Test
    func draggingExitHidesHint() {
        let (window, overlay) = makeOverlay()
        defer { close(window) }
        showHint(in: overlay)
        overlay.draggingExited(nil)
        #expect(overlay.hintBadgeView.isHidden)
        #expect(overlay.hintBadgeView.accessibilityLabel() == nil)
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
        let popup = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        popup.isReleasedWhenClosed = false
        defer { close(popup) }
        showHint(in: overlay)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: popup)
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

    @Test
    func closingOrDetachingWindowHidesHint() {
        let (window, overlay) = makeOverlay()
        defer { close(window) }
        showHint(in: overlay)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        #expect(overlay.hintBadgeView.isHidden)
        showHint(in: overlay, sequenceNumber: 2)
        window.contentView = NSView()
        #expect(overlay.hintBadgeView.isHidden)
    }

    @Test
    func ownWindowBecomingKeyPreservesLiveHint() {
        let (window, overlay) = makeOverlay()
        defer { close(window) }
        showHint(in: overlay)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(!overlay.hintBadgeView.isHidden)
    }

    @Test
    func dismissedDragCannotReshowHintButNextDragCan() {
        let (window, overlay) = makeOverlay()
        defer { close(window) }
        showHint(in: overlay)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        overlay.hintPresentation.begin(sequenceNumber: 1)
        overlay.hintPresentation.show(
            sequenceNumber: 1, text: "stale", centeredIn: overlay.bounds, clippedTo: overlay.bounds
        )
        #expect(overlay.hintBadgeView.isHidden)
        showHint(in: overlay, sequenceNumber: 2)
        overlay.hintPresentation.show(
            sequenceNumber: 1, text: "stale", centeredIn: overlay.bounds, clippedTo: overlay.bounds
        )
        #expect(overlay.hintBadgeView.accessibilityLabel() == "Hold Shift to open as split")
    }

    @Test(arguments: [NSEvent.EventType.leftMouseUp, .rightMouseUp, .otherMouseUp, .mouseMoved])
    func releaseDismissesHintWithoutConsumingNativeEvent(_ type: NSEvent.EventType) throws {
        let (window, overlay) = makeOverlay()
        defer { close(window) }
        showHint(in: overlay)
        let event = try #require(NSEvent.mouseEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0
        ))
        #expect(overlay.hintPresentation.handleEvent(event) === event)
        #expect(overlay.hintBadgeView.isHidden)
    }

    @Test
    func escapeDismissesHintWithoutConsumingNativeCancellation() throws {
        let (window, overlay) = makeOverlay()
        defer { close(window) }
        showHint(in: overlay)
        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        #expect(overlay.hintPresentation.handleEvent(escape) === escape)
        #expect(overlay.hintBadgeView.isHidden)
    }

    @Test
    func displayDeadlineDismissesEvenIfAppKitKeepsUpdatingDrag() {
        let (window, _) = makeOverlay()
        defer { close(window) }
        let presentation = FileDropHintPresentation(displayDuration: .zero)
        presentation.setHostWindow(window)
        presentation.begin(sequenceNumber: 10)
        let bounds = CGRect(x: 0, y: 0, width: 420, height: 280)
        presentation.show(sequenceNumber: 10, text: "hint", centeredIn: bounds, clippedTo: bounds)
        // Drain the real zero-duration deadline; no wall-clock delay is needed to show the hint.
        let limit = Date().addingTimeInterval(1)
        while !presentation.badge.isHidden, Date() < limit {
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        }
        #expect(presentation.badge.isHidden)
        presentation.show(sequenceNumber: 10, text: "stale", centeredIn: bounds, clippedTo: bounds)
        #expect(presentation.badge.isHidden)
    }
}
