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


// MARK: - Runtime surface creation and headless startup window
extension TerminalOffscreenStartupTests {
    func testPlainSurfaceDoesNotStartRuntimeBeforeWindowAttachmentOrInput() {
        let panel = TerminalPanel(workspaceId: UUID())

        XCTAssertNil(panel.hostedView.window)
        XCTAssertFalse(panel.surface.debugHasHeadlessStartupWindowForTesting())
        XCTAssertEqual(
            panel.surface.debugRuntimeSurfaceCreateAttemptCountForTesting(),
            0,
            "Empty terminal surfaces should stay lazy until they attach or receive input so tests and background helpers do not spawn idle PTYs."
        )
    }

    func testPlainHostedViewWindowAttachmentCreatesRuntimeSurface() throws {
        let panel = TerminalPanel(workspaceId: UUID())
        XCTAssertEqual(panel.hostedView.debugSurfaceId, panel.surface.id)
        XCTAssertNil(panel.surface.surface)
        XCTAssertFalse(panel.surface.debugHasHeadlessStartupWindowForTesting())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            panel.hostedView.removeFromSuperview()
            panel.surface.teardownSurface()
            window.orderOut(nil)
        }

        let contentView = try XCTUnwrap(window.contentView)
        panel.hostedView.frame = contentView.bounds
        panel.hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(panel.hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNotNil(
            panel.surface.surface,
            "A direct AppKit-hosted terminal view must create its runtime surface once it enters a real window."
        )
        XCTAssertGreaterThan(panel.surface.debugRuntimeSurfaceCreateAttemptCountForTesting(), 0)
    }

    func testInitialInputSurfaceAttemptsRuntimeCreationBeforeWindowAttachment() {
        let panel = TerminalPanel(
            workspaceId: UUID(),
            initialInput: "echo resume\n"
        )

        XCTAssertTrue(
            panel.surface.debugHasHeadlessStartupWindowForTesting(),
            "Restored auto-resume input should bootstrap through a hidden window rather than waiting for a user-focused portal."
        )
        XCTAssertGreaterThan(
            panel.surface.debugRuntimeSurfaceCreateAttemptCountForTesting(),
            0,
            "Restored auto-resume input must start the terminal runtime without waiting for a window attach."
        )
    }

    func testInitialCommandSurfaceAttemptsRuntimeCreationBeforeWindowAttachment() {
        let panel = TerminalPanel(
            workspaceId: UUID(),
            initialCommand: "echo startup"
        )

        XCTAssertTrue(
            panel.surface.debugHasHeadlessStartupWindowForTesting(),
            "Command-launched offscreen terminals should bootstrap through a hidden window rather than waiting for a user-focused portal."
        )
        XCTAssertGreaterThan(
            panel.surface.debugRuntimeSurfaceCreateAttemptCountForTesting(),
            0,
            "Offscreen command-launched terminals must start the runtime without waiting for a window attach."
        )
    }

    func testHeadlessStartupWindowDoesNotCountAsViewInWindowForHealth() {
        let panel = TerminalPanel(
            workspaceId: UUID(),
            initialCommand: "echo startup"
        )

        XCTAssertTrue(panel.surface.debugHasHeadlessStartupWindowForTesting())
        XCTAssertNotNil(panel.hostedView.window)
        XCTAssertNil(panel.surface.uiWindow)
        XCTAssertFalse(panel.hostedView.debugPortalVisibleInUI)
        XCTAssertFalse(panel.hostedView.debugPortalActive)
        XCTAssertFalse(
            panel.surface.isViewInWindow,
            "surface.health must keep reporting offscreen bootstrap terminals as unhosted."
        )
    }

    func testForceRefreshIgnoresHeadlessStartupWindow() throws {
#if DEBUG
        let panel = TerminalPanel(
            workspaceId: UUID(),
            initialCommand: "echo startup"
        )
        XCTAssertTrue(panel.surface.debugHasHeadlessStartupWindowForTesting())
        XCTAssertNotNil(panel.hostedView.window)
        XCTAssertNil(panel.surface.uiWindow)

        panel.surface.resetDebugForceRefreshCount()
        panel.surface.forceRefresh(reason: "test.headless")

        XCTAssertEqual(
            panel.surface.debugForceRefreshCount(),
            0,
            "forceRefresh should ignore hidden bootstrap windows and wait for a real UI host."
        )
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

}
