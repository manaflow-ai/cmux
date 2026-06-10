import XCTest
import Testing
import CmuxControlSocket
import CmuxTerminalCopyMode
import CmuxSocketControl
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import CMUXMobileCore
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Key repeat, visibility, and focus driven surface refresh
extension TerminalNotificationDirectInteractionTests {
    func testPrintableKeyRepeatDoesNotForceSurfaceRefresh() throws {
#if DEBUG
        let window = makeWindow()
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let surfaceView = surfaceView(in: hostedView) as? GhosttyNSView else {
            XCTFail("Expected terminal surface view")
            return
        }
        XCTAssertNotNil(surface.surface, "Expected runtime surface before sending repeat key input")
        XCTAssertTrue(window.makeFirstResponder(surfaceView))

        let previousTextInputEventHandler = GhosttyNSView.debugTextInputEventHandler
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        defer {
            GhosttyNSView.debugTextInputEventHandler = previousTextInputEventHandler
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            withExtendedLifetime(surface) {}
        }

        GhosttyNSView.debugTextInputEventHandler = { _, _ in false }
        var forwardedRepeatCount = 0
        var forwardedTexts: [String] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_REPEAT, keyEvent.keycode == 0 else { return }
            forwardedRepeatCount += 1
            if let text = keyEvent.text {
                forwardedTexts.append(String(cString: text))
            }
        }

        surface.resetDebugForceRefreshCount()

        for index in 0..<3 {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime + (Double(index) * 0.001),
                windowNumber: window.windowNumber,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: true,
                keyCode: 0
            ))

            withExtendedLifetime(surface) {
                surfaceView.keyDown(with: event)
            }
        }

        XCTAssertEqual(forwardedRepeatCount, 3, "Repeat text keyDown events should still reach Ghostty")
        XCTAssertEqual(forwardedTexts, ["a", "a", "a"], "Printable repeat should exercise the fallback text path")
        XCTAssertEqual(
            surface.debugForceRefreshCount(),
            0,
            "Printable key repeat must rely on Ghostty wakeups instead of forcing a synchronous surface refresh per key"
        )
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

    func testIMECommittedKeyRepeatDoesNotForceSurfaceRefresh() throws {
#if DEBUG
        let window = makeWindow()
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let surfaceView = surfaceView(in: hostedView) as? GhosttyNSView else {
            XCTFail("Expected terminal surface view")
            return
        }
        XCTAssertNotNil(surface.surface, "Expected runtime surface before sending repeat IME input")
        XCTAssertTrue(window.makeFirstResponder(surfaceView))

        let previousTextInputEventHandler = GhosttyNSView.debugTextInputEventHandler
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        defer {
            GhosttyNSView.debugTextInputEventHandler = previousTextInputEventHandler
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            withExtendedLifetime(surface) {}
        }

        GhosttyNSView.debugTextInputEventHandler = { view, _ in
            view.insertText("あ", replacementRange: NSRange(location: NSNotFound, length: 0))
            return true
        }
        var forwardedRepeatCount = 0
        var forwardedTexts: [String] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_REPEAT, keyEvent.keycode == 0 else { return }
            forwardedRepeatCount += 1
            if let text = keyEvent.text {
                forwardedTexts.append(String(cString: text))
            }
        }

        surface.resetDebugForceRefreshCount()

        for index in 0..<3 {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime + (Double(index) * 0.001),
                windowNumber: window.windowNumber,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: true,
                keyCode: 0
            ))

            withExtendedLifetime(surface) {
                surfaceView.keyDown(with: event)
            }
        }

        XCTAssertEqual(forwardedRepeatCount, 3, "Repeat IME text keyDown events should still reach Ghostty")
        XCTAssertEqual(forwardedTexts, ["あ", "あ", "あ"], "IME repeat should exercise the accumulated committed-text path")
        XCTAssertEqual(
            surface.debugForceRefreshCount(),
            0,
            "IME key repeat must rely on Ghostty wakeups instead of forcing a synchronous surface refresh per key"
        )
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

    func testVisibilityRestoreRefreshesSurfaceWhileTerminalIsInactive() throws {
#if DEBUG
        let window = makeWindow()
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNotNil(
            surface.surface,
            "Expected runtime surface before measuring visibility-restore redraws"
        )

        hostedView.setActive(false)
        hostedView.setVisibleInUI(false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        surface.resetDebugForceRefreshCount()
        hostedView.setVisibleInUI(true)
        drainMainQueue()

        XCTAssertEqual(
            surface.debugForceRefreshCount(),
            1,
            "Restoring panel visibility should force a redraw even when focus recovery is inactive"
        )
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

    func testDirectFirstResponderFocusRefreshesCursorStateAfterForeignResponder() throws {
#if DEBUG
        let window = makeWindow()
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        let otherResponder = FocusProbeView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        contentView.addSubview(otherResponder)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let surfaceView = surfaceView(in: hostedView) as? GhosttyNSView else {
            XCTFail("Expected terminal surface view")
            return
        }
        XCTAssertNotNil(surface.surface, "Expected runtime surface before measuring focus redraws")
        XCTAssertTrue(window.makeFirstResponder(surfaceView))
        XCTAssertTrue(window.makeFirstResponder(otherResponder))

        surface.resetDebugForceRefreshCount()
        XCTAssertTrue(window.makeFirstResponder(surfaceView))

        XCTAssertGreaterThan(
            surface.debugForceRefreshCount(),
            0,
            "Clicking back into the terminal should redraw immediately so the cursor reflects focused input"
        )
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }
}
