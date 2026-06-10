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


// MARK: - Search overlay mounting, focus, and portal churn survival
extension GhosttySurfaceOverlayTests {
    func testSearchOverlayMountsAndUnmountsWithSearchState() {
        let surface = makeTrackedTerminalSurface()
        let hostedView = surface.hostedView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()

        XCTAssertFalse(hostedView.debugHasSearchOverlay())

        let searchState = TerminalSurface.SearchState(needle: "example")
        hostedView.setSearchOverlay(searchState: searchState)
        waitUntil(description: "search overlay to mount") {
            hostedView.debugHasSearchOverlay()
        }
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        hostedView.setSearchOverlay(searchState: nil)
        waitUntil(description: "search overlay to unmount") {
            !hostedView.debugHasSearchOverlay()
        }
        XCTAssertFalse(hostedView.debugHasSearchOverlay())
    }

    func testRapidSearchOverlayToggleDoesNotLeaveStaleOverlayMounted() {
        let surface = makeTrackedTerminalSurface()
        let hostedView = surface.hostedView

        hostedView.setSearchOverlay(searchState: TerminalSurface.SearchState(needle: "example"))
        hostedView.setSearchOverlay(searchState: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertFalse(
            hostedView.debugHasSearchOverlay(),
            "A stale deferred mount must not resurrect the find overlay after it closes"
        )
    }

    func testSearchOverlayFocusesSearchFieldAfterDeferredAttach() {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = previousAppDelegate ?? AppDelegate()
        let originalTabManager = appDelegate.tabManager
        let manager = TabManager()
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager

        let window = KeyStatusTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            appDelegate.tabManager = originalTabManager
            AppDelegate.shared = previousAppDelegate
            window.orderOut(nil)
        }

        guard let workspace = manager.selectedWorkspace,
              let terminalPanel = workspace.focusedTerminalPanel else {
            XCTFail("Expected initial focused terminal panel")
            return
        }

        let surface = terminalPanel.surface
        let hostedView = terminalPanel.hostedView
        surfacesToRelease.append(surface)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)

        let searchState = TerminalSurface.SearchState(needle: "")
        surface.searchState = searchState
        hostedView.setSearchOverlay(searchState: searchState)
        waitUntil(description: "search overlay to mount and expose field") {
            self.findEditableTextField(in: hostedView) != nil
        }

        guard let searchField = findEditableTextField(in: hostedView) else {
            XCTFail("Expected mounted find text field")
            return
        }

        waitUntil(description: "search field to become first responder") {
            self.firstResponderOwnsTextField(window.firstResponder, textField: searchField)
        }
    }

    func testStartOrFocusTerminalSearchReusesExistingSearchState() {
        let surface = makeTrackedTerminalSurface()
        let existingSearchState = TerminalSurface.SearchState(needle: "existing")
        surface.searchState = existingSearchState

        var focusNotificationCount = 0
        XCTAssertTrue(
            startOrFocusTerminalSearch(surface) { _ in
                focusNotificationCount += 1
            }
        )

        XCTAssertTrue(surface.searchState === existingSearchState)
        XCTAssertEqual(
            focusNotificationCount,
            1,
            "Re-triggering terminal Find should refocus the existing overlay without recreating state"
        )
    }

    func testEscapeDismissingFindOverlayDoesNotLeakEscapeKeyUpToTerminal() {
        _ = NSApplication.shared

        let surface = makeTrackedTerminalSurface()
        let hostedView = surface.hostedView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            window.orderOut(nil)
        }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let searchState = TerminalSurface.SearchState(needle: "")
        surface.searchState = searchState
        hostedView.setSearchOverlay(searchState: searchState)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let searchField = findEditableTextField(in: hostedView) else {
            XCTFail("Expected mounted find text field")
            return
        }
        window.makeFirstResponder(searchField)

        var escapeKeyUpCount = 0
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.action == GHOSTTY_ACTION_RELEASE, keyEvent.keycode == 53 else { return }
            escapeKeyUpCount += 1
        }

        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let escapeKeyDown = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ), let escapeKeyUp = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp + 0.001,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ) else {
            XCTFail("Failed to construct Escape key events")
            return
        }

        NSApp.sendEvent(escapeKeyDown)
        NSApp.sendEvent(escapeKeyUp)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(surface.searchState, "Escape should dismiss find overlay when search text is empty")
        XCTAssertEqual(
            escapeKeyUpCount,
            0,
            "Escape used to dismiss find overlay must not pass through to the terminal key-up path"
        )
    }

    func testSearchOverlayMountDoesNotRetainTerminalSurface() {
        weak var weakSurface: TerminalSurface?

        var surface: TerminalSurface? = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        weakSurface = surface
        guard let hostedView = surface?.hostedView else {
            XCTFail("Expected hosted terminal view")
            return
        }
        hostedView.setSearchOverlay(searchState: TerminalSurface.SearchState(needle: "retain-check"))

        waitUntil(description: "search overlay to mount") {
            hostedView.debugHasSearchOverlay()
        }
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        surface?.releaseSurfaceForTesting()
        surface = nil
        waitUntil(description: "terminal surface to deallocate after search overlay mount") {
            weakSurface == nil
        }
        XCTAssertNil(weakSurface, "Mounted search overlay must not retain TerminalSurface")
    }

    func testSearchOverlaySurvivesPortalRebindDuringSplitLikeChurn() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let portal = WindowTerminalPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchorA = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 140))
        let anchorB = NSView(frame: NSRect(x: 220, y: 20, width: 180, height: 140))
        contentView.addSubview(anchorA)
        contentView.addSubview(anchorB)

        let surface = makeTrackedTerminalSurface()
        let hostedView = surface.hostedView
        hostedView.setSearchOverlay(searchState: TerminalSurface.SearchState(needle: "split"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchorA, visibleInUI: true)
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchorB, visibleInUI: true)
        XCTAssertTrue(
            hostedView.debugHasSearchOverlay(),
            "Split-like anchor churn should not unmount terminal search overlay"
        )
    }

    func testSearchOverlaySurvivesPortalVisibilityToggleDuringWorkspaceSwitchLikeChurn() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let portal = WindowTerminalPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 40, width: 220, height: 160))
        contentView.addSubview(anchor)

        let surface = makeTrackedTerminalSurface()
        let hostedView = surface.hostedView
        hostedView.setSearchOverlay(searchState: TerminalSurface.SearchState(needle: "workspace"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchor, visibleInUI: true)
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchor, visibleInUI: false)
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchor, visibleInUI: true)
        XCTAssertTrue(
            hostedView.debugHasSearchOverlay(),
            "Workspace-switch-like visibility toggles should not unmount terminal search overlay"
        )
    }
}
