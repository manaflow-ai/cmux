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


// MARK: - Key-down surface recovery
extension TerminalNotificationDirectInteractionTests {
    func testKeyDownRecoversReleasedSurfaceWhileHostedViewIsDetached() throws {
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
        XCTAssertNotNil(surface.surface, "Expected runtime surface before simulating the detach race")

        surface.releaseSurfaceForTesting()
        XCTAssertNil(surface.surface, "Expected runtime surface to be released for the regression setup")

        hostedView.removeFromSuperview()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(surfaceView.window, "Expected hosted terminal view to be detached from any window")

        let event = makeKeyEvent(characters: "a", keyCode: 0, window: window)
        surfaceView.keyDown(with: event)
        waitForRuntimeSurface(surface)

        XCTAssertNotNil(
            surface.surface,
            "Missing-surface keyDown should request background surface recreation instead of leaving terminal input dead"
        )
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

    func testKeyDownRecoveryDoesNotReplayFocusAfterResponderMovesAway() throws {
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
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let surfaceView = surfaceView(in: hostedView) as? GhosttyNSView else {
            XCTFail("Expected terminal surface view")
            return
        }

        XCTAssertTrue(window.makeFirstResponder(surfaceView))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(surface.debugDesiredFocusState(), "Focused terminal should start with desired Ghostty focus")

        surface.releaseSurfaceForTesting()
        XCTAssertNil(surface.surface, "Expected runtime surface to be released for the regression setup")

        hostedView.removeFromSuperview()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(surfaceView.window, "Expected hosted terminal view to be detached from any window")
        let detachedViewStillFirstResponder = (window.firstResponder as? NSView) === surfaceView
        if !detachedViewStillFirstResponder {
            // Some runners clear the window responder during detach without calling the view hook.
            surface.recordExternalFocusState(false)
            XCTAssertFalse(
                surface.debugDesiredFocusState(),
                "Runner already moved first responder away, so desired Ghostty focus should be cleared before recovery"
            )
        }

        let event = makeKeyEvent(characters: "a", keyCode: 0, window: window)
        surfaceView.keyDown(with: event)

        XCTAssertTrue(window.makeFirstResponder(otherResponder))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(
            (window.firstResponder as? NSView) === otherResponder,
            "Expected focus to move to the replacement responder"
        )
        XCTAssertFalse(
            surface.debugDesiredFocusState(),
            "Responder loss after a missing-surface keyDown should clear desired Ghostty focus before recovery completes"
        )
        waitForRuntimeSurface(surface)

        XCTAssertNotNil(surface.surface, "Expected missing-surface recovery to still recreate the runtime surface")
        XCTAssertFalse(
            surface.debugDesiredFocusState(),
            "Recovered runtime surface should not restore focus after the pane already lost first responder"
        )
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

    func testKeyDownRecoveryDoesNotRecreateClosedSurface() throws {
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
        XCTAssertNotNil(surface.surface, "Expected runtime surface before simulating close lifecycle teardown")

        surface.beginPortalCloseLifecycle(reason: "test.close")
        surface.teardownSurface()
        XCTAssertNil(surface.surface, "Teardown should release the runtime surface")
        XCTAssertEqual(surface.portalBindingStateLabel(), "closed")

        hostedView.removeFromSuperview()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(surfaceView.window, "Expected hosted terminal view to be detached from any window")

        let event = makeKeyEvent(characters: "a", keyCode: 0, window: window)
        surfaceView.keyDown(with: event)
        drainMainQueue()

        XCTAssertNil(
            surface.surface,
            "Missing-surface keyDown should not recreate a Ghostty runtime surface after close lifecycle teardown"
        )
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

}
