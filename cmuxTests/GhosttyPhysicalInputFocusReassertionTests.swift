import AppKit
import CmuxTerminal
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
@MainActor
final class GhosttyPhysicalInputFocusReassertionTests: XCTestCase {
    private final class FocusObservingSurfaceView: GhosttyNSView {
        private(set) var forcedNativeFocusReassertionCount = 0

        override func reassertTerminalFocusForInputIfFirstResponder(
            forceNative: Bool = false
        ) -> Bool {
            if forceNative {
                forcedNativeFocusReassertionCount += 1
            }
            return super.reassertTerminalFocusForInputIfFirstResponder(
                forceNative: forceNative
            )
        }
    }

    private struct FocusObservingSurfaceViewFactory: TerminalSurfaceViewProviding {
        func makeSurfaceViews(
            initialFrame: NSRect
        ) -> (
            surfaceView: any TerminalSurfaceNativeViewing,
            paneHost: any TerminalSurfacePaneHosting
        ) {
            let surfaceView = FocusObservingSurfaceView(frame: initialFrame)
            return (
                surfaceView,
                GhosttySurfaceScrollView(surfaceView: surfaceView)
            )
        }
    }

    private struct HostedTerminal {
        let surface: TerminalSurface
        let hostedView: GhosttySurfaceScrollView
        let surfaceView: FocusObservingSurfaceView
        let window: NSWindow
    }

    private final class OverlayResponderView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    func testControlKeyDownForcesNativeFocusRepairBeforeForwarding() throws {
        let terminal = try makeHostedTerminal()
        defer { terminal.window.orderOut(nil) }

        try focusTerminal(terminal)
        terminal.surface.recordExternalFocusState(true)
        _ = try XCTUnwrap(terminal.surface.surface)
        XCTAssertTrue(
            terminal.surface.debugDesiredFocusState(),
            "Regression setup explicitly models deduplicated focus while native focus may have drifted"
        )

        let event = try makeKeyDownEvent(
            characters: "\u{0004}",
            charactersIgnoringModifiers: "d",
            modifierFlags: [.control],
            keyCode: 2,
            window: terminal.window
        )
        terminal.surfaceView.keyDown(with: event)

        XCTAssertEqual(
            terminal.surfaceView.forcedNativeFocusReassertionCount,
            1,
            "Control input must bypass the deduplicated model state and repair native Ghostty focus"
        )
    }

    func testPrintableKeyDownReassertsGhosttyFocusWhenFirstResponderSurfaceFocusDrifted() throws {
        let terminal = try makeHostedTerminal()
        defer { terminal.window.orderOut(nil) }
        let hasLiveSurface = terminal.surface.hasLiveSurface

        try focusTerminal(terminal)
        terminal.surface.recordExternalFocusState(false)
        XCTAssertFalse(
            terminal.surface.debugDesiredFocusState(),
            "Regression setup should simulate Ghostty focus drifting false while AppKit first responder remains on the terminal"
        )

        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
        }

        var forwardedText: String?
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS,
                  keyEvent.keycode == 0,
                  let text = keyEvent.text else { return }
            forwardedText = String(cString: text)
        }

        let event = try makeKeyDownEvent(
            characters: "a",
            charactersIgnoringModifiers: "a",
            keyCode: 0,
            window: terminal.window
        )
        terminal.surfaceView.keyDown(with: event)

        if hasLiveSurface {
            XCTAssertEqual(forwardedText, "a", "Regression setup should exercise the printable Ghostty key path")
        }
        XCTAssertTrue(
            terminal.surface.debugDesiredFocusState(),
            "Physical printable input should restore Ghostty focus before sending the key"
        )
    }

    func testDirectCommittedTextReassertsGhosttyFocusWhenFirstResponderSurfaceFocusDrifted() throws {
        let terminal = try makeHostedTerminal()
        defer { terminal.window.orderOut(nil) }
        let hasLiveSurface = terminal.surface.hasLiveSurface

        try focusTerminal(terminal)
        terminal.surface.recordExternalFocusState(false)
        XCTAssertFalse(
            terminal.surface.debugDesiredFocusState(),
            "Regression setup should simulate Ghostty focus drifting false while AppKit first responder remains on the terminal"
        )

        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
        }

        var forwardedText: String?
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_PRESS,
                  keyEvent.keycode == 0,
                  let text = keyEvent.text else { return }
            forwardedText = String(cString: text)
        }

        terminal.surfaceView.insertText(
            "committed",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        if hasLiveSurface {
            XCTAssertEqual(forwardedText, "committed", "Regression setup should exercise direct NSTextInputClient commit")
        }
        XCTAssertTrue(
            terminal.surface.debugDesiredFocusState(),
            "Direct committed text should restore Ghostty focus before sending text"
        )
    }

    func testDirectCommittedTextDoesNotReassertGhosttyFocusWhenDescendantOverlayOwnsFirstResponder() throws {
        let terminal = try makeHostedTerminal()
        defer { terminal.window.orderOut(nil) }

        try focusTerminal(terminal)
        terminal.surface.recordExternalFocusState(false)

        let overlayResponder = OverlayResponderView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        terminal.surfaceView.addSubview(overlayResponder)
        defer { overlayResponder.removeFromSuperview() }

        XCTAssertTrue(terminal.window.makeFirstResponder(overlayResponder))
        XCTAssertTrue(overlayResponder.isDescendant(of: terminal.surfaceView))
        XCTAssertFalse(
            terminal.surface.debugDesiredFocusState(),
            "Regression setup should simulate an overlay keeping Ghostty focus false while it owns AppKit focus"
        )

        terminal.surfaceView.insertText(
            "overlay-owned",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        XCTAssertFalse(
            terminal.surface.debugDesiredFocusState(),
            "Input readiness should not restore Ghostty focus for descendant overlay responders"
        )
    }

    private func makeHostedTerminal() throws -> HostedTerminal {
        _ = NSApplication.shared

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil,
            dependencies: runtimeDependencies()
        )
        let hostedView = surface.hostedView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        let contentView = try XCTUnwrap(window.contentView)
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        return HostedTerminal(
            surface: surface,
            hostedView: hostedView,
            surfaceView: try XCTUnwrap(
                findGhosttyNSView(in: hostedView) as? FocusObservingSurfaceView
            ),
            window: window
        )
    }

    private func runtimeDependencies() -> TerminalSurfaceRuntimeDependencies {
        let live = GhosttyApp.terminalSurfaceRuntimeDependencies
        return TerminalSurfaceRuntimeDependencies(
            registry: live.registry,
            engine: live.engine,
            viewProvider: FocusObservingSurfaceViewFactory(),
            spawnPolicy: live.spawnPolicy,
            byteTee: live.byteTee,
            rendererRealization: live.rendererRealization,
            hibernationRecorder: live.hibernationRecorder,
            runtimeTeardown: live.runtimeTeardown,
            restoreSpawnScheduler: live.restoreSpawnScheduler,
            runtimeFilesystem: live.runtimeFilesystem,
            sessionPortBase: live.sessionPortBase,
            sessionPortRangeSize: live.sessionPortRangeSize,
            scrollbackReplayEnvironmentKey: live.scrollbackReplayEnvironmentKey,
            globalFontMagnificationPercent: live.globalFontMagnificationPercent
        )
    }

    private func focusTerminal(_ terminal: HostedTerminal) throws {
        XCTAssertTrue(terminal.window.makeFirstResponder(terminal.surfaceView))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(terminal.hostedView.isSurfaceViewFirstResponder())
    }

    private func makeKeyDownEvent(
        characters: String,
        charactersIgnoringModifiers: String,
        modifierFlags: NSEvent.ModifierFlags = [],
        keyCode: UInt16,
        window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
#endif
