import AppKit
import CmuxTerminal
import GhosttyKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AppDelegateShortcutRoutingTests {
    func coldCloudTerminalPanel(workspace: Workspace) -> TerminalPanel {
        let base = GhosttyApp.terminalSurfaceRuntimeDependencies
        let dependencies = TerminalSurfaceRuntimeDependencies(
            registry: base.registry, engine: ColdCloudTerminalEngine(),
            viewProvider: base.viewProvider, spawnPolicy: base.spawnPolicy,
            byteTee: base.byteTee, rendererRealization: base.rendererRealization,
            hibernationRecorder: base.hibernationRecorder, runtimeTeardown: base.runtimeTeardown,
            restoreSpawnScheduler: base.restoreSpawnScheduler, runtimeFilesystem: base.runtimeFilesystem,
            sessionPortBase: base.sessionPortBase, sessionPortRangeSize: base.sessionPortRangeSize,
            scrollbackReplayEnvironmentKey: base.scrollbackReplayEnvironmentKey,
            globalFontMagnificationPercent: base.globalFontMagnificationPercent
        )
        let surface = TerminalSurface(
            tabId: workspace.id, context: GHOSTTY_SURFACE_CONTEXT_SPLIT, configTemplate: nil,
            ioMode: .manualMirror, manualInputHandler: { _ in }, dependencies: dependencies
        )
        return TerminalPanel(workspaceId: workspace.id, surface: surface)
    }

    func focusHostedTerminalForRepairTesting(
        window: NSWindow,
        hostedView: GhosttySurfaceScrollView
    ) {
        window.makeKeyAndOrderFront(nil)
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        let deadline = Date(timeIntervalSinceNow: 1)
        repeat {
            window.displayIfNeeded()
            if hostedView.surfaceView.window === window,
               window.makeFirstResponder(hostedView.surfaceView),
               hostedView.isSurfaceViewFirstResponder() {
                break
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        } while Date() < deadline
        XCTAssertTrue(
            hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to own first responder before repair test"
        )
    }

    func installStrandedResponderDriftForTesting(
        _ responder: NSView,
        in window: NSWindow,
        hostedView: GhosttySurfaceScrollView
    ) {
        (window.contentView?.superview ?? window.contentView)?.addSubview(responder)
        XCTAssertTrue(window.makeFirstResponder(responder), "Expected test to install a stranded responder")
        XCTAssertTrue(window.firstResponder === responder, "Expected real first responder drift before removal")
        responder.removeFromSuperview()
        XCTAssertNil(responder.window, "Expected a simulated stranded responder")
        XCTAssertFalse(
            hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to lose first responder before repaired typing"
        )
    }

    func installVisibleResponderDriftForTesting(
        _ responder: NSView,
        in window: NSWindow,
        hostedView: GhosttySurfaceScrollView,
        mismatchMessage: String
    ) {
        (window.contentView?.superview ?? window.contentView)?.addSubview(responder)
        XCTAssertTrue(responder.window === window, "Expected a simulated same-window responder")
        XCTAssertTrue(window.makeFirstResponder(responder), "Expected test to install a visible wrong first responder")
        XCTAssertTrue(window.firstResponder === responder, "Expected real same-window responder drift before repair")
        XCTAssertFalse(hostedView.responderMatchesPreferredKeyboardFocus(responder), mismatchMessage)
        XCTAssertFalse(
            hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to lose first responder before repaired typing"
        )
    }

    func installSearchResponderDriftForTesting(
        _ responder: NSView,
        in window: NSWindow,
        hostedView: GhosttySurfaceScrollView,
        searchField: NSTextField
    ) {
        (window.contentView?.superview ?? window.contentView)?.addSubview(responder)
        XCTAssertTrue(responder.window === window, "Expected a simulated same-window responder")
        XCTAssertTrue(window.makeFirstResponder(responder), "Expected test to install a visible wrong first responder")
        XCTAssertTrue(window.firstResponder === responder, "Expected real same-window responder drift before repair")
        XCTAssertFalse(
            hostedView.responderMatchesPreferredKeyboardFocus(responder),
            "Expected the simulated responder to disagree with terminal search focus"
        )
        XCTAssertFalse(
            repairProbeFirstResponderOwnsTextField(window.firstResponder, textField: searchField),
            "Expected terminal search field to lose first responder before repaired typing"
        )
    }

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

    private func repairProbeFirstResponderOwnsTextField(
        _ firstResponder: NSResponder?,
        textField: NSTextField
    ) -> Bool {
        if firstResponder === textField {
            return true
        }
        if let editor = firstResponder as? NSTextView,
           editor.isFieldEditor,
           editor.delegate as? NSTextField === textField {
            return true
        }
        return false
    }
}

/// The cold-input fixture owns an uninitialized engine explicitly. It must
/// not depend on renderer startup being delayed by an unrelated disk task.
@MainActor
private final class ColdCloudTerminalEngine: TerminalEngineHosting {
    var runtimeApp: ghostty_app_t? { nil }
    var runtimeConfig: ghostty_config_t? { nil }
    var userGhosttyShellIntegrationMode: String { "none" }
    var hasUserGhosttyCommand: Bool { false }
    var resolvedUserShell: String? { nil }
    var terminalFontConfigurationGeneration: UInt64 { 0 }
    var terminalFontConfigurationRuntimePoints: Float32 { 14 }
}
