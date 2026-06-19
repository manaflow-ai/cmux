import AppKit
import CmuxTerminal
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AppDelegateShortcutRoutingTests {
    func installFocusedTerminalRepairProbeForTesting(
        appDelegate: AppDelegate,
        keyCode: UInt32
    ) -> (
        repairCount: () -> Int,
        repairResponder: () -> NSResponder?,
        forwardedKeyDownCount: () -> Int,
        restore: () -> Void
    ) {
        var repairCount = 0
        var repairResponder: NSResponder?
        let previousRepairObserver = appDelegate.debugFocusedTerminalKeyRepairObserverForTesting
        appDelegate.debugFocusedTerminalKeyRepairObserverForTesting = { window, event, responder in
            previousRepairObserver?(window, event, responder)
            guard UInt32(event.keyCode) == keyCode else { return }
            repairCount += 1
            repairResponder = responder
        }

        var forwardedKeyDownCount = 0
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS, keyEvent.keycode == keyCode else { return }
            forwardedKeyDownCount += 1
        }

        return (
            repairCount: { repairCount },
            repairResponder: { repairResponder },
            forwardedKeyDownCount: { forwardedKeyDownCount },
            restore: {
                appDelegate.debugFocusedTerminalKeyRepairObserverForTesting = previousRepairObserver
                GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            }
        )
    }
}
