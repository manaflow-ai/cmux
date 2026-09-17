import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct WorkspaceSwitchPortalSignalRouterTests {
    @Test
    func relaysOnlySignalsFromItsAttachedWindow() {
        let sourceCenter = NotificationCenter()
        let router = WorkspaceSwitchPortalSignalRouter(notificationCenter: sourceCenter)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let otherWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        defer {
            window.orderOut(nil)
            otherWindow.orderOut(nil)
        }
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        otherWindow.contentView = NSView(frame: otherWindow.contentRect(forFrameRect: otherWindow.frame))
        router.attach(to: window)

        var relayedCount = 0
        let observer = router.notificationCenter.addObserver(
            forName: .terminalPortalVisibilityDidChange,
            object: nil,
            queue: nil
        ) { _ in
            relayedCount += 1
        }
        defer { router.notificationCenter.removeObserver(observer) }

        let ownedView = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: .zero)
        )
        window.contentView?.addSubview(ownedView)
        router.observe(
            terminalHostedView: ownedView,
            terminalSurface: nil,
            browserWebView: nil
        )
        sourceCenter.post(name: .terminalPortalVisibilityDidChange, object: ownedView)
        #expect(relayedCount == 1)

        let unrelatedView = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: .zero)
        )
        otherWindow.contentView?.addSubview(unrelatedView)
        sourceCenter.post(name: .terminalPortalVisibilityDidChange, object: unrelatedView)
        #expect(relayedCount == 1)
    }
}
