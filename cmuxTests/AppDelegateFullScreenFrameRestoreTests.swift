import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct AppDelegateFullScreenFrameRestoreTests {
    @Test(.enabled(
        if: NSScreen.screens.contains { $0.visibleFrame.maxY < $0.frame.maxY },
        "No screen with a visible menu-bar inset is available"
    ))
    func exitingNativeFullScreenFitsFullDisplayFrameBelowMenuBar() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first(where: {
            $0.visibleFrame.maxY < $0.frame.maxY
        }))

        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let windowId = appDelegate.createMainWindow(shouldActivate: false)
        let window = try #require(appDelegate.mainWindow(for: windowId) as? CmuxMainWindow)
#if DEBUG
        let previousConfirmationHandler = appDelegate.debugCloseMainWindowConfirmationHandler
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }
#endif
        defer {
            window.animationBehavior = .none
            window.orderOut(nil)
            window.close()
#if DEBUG
            appDelegate.debugCloseMainWindowConfirmationHandler = previousConfirmationHandler
#endif
        }

        window.setFrame(screen.frame, display: false)
        #expect(window.frame.maxY > screen.visibleFrame.maxY)

        window.delegate?.windowDidExitFullScreen?(
            Notification(name: NSWindow.didExitFullScreenNotification, object: window)
        )

        #expect(screen.visibleFrame.contains(window.frame))
        #expect(window.frame.maxY <= screen.visibleFrame.maxY)
    }
}
