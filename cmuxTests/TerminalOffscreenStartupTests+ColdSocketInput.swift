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


// MARK: - Cold socket input queueing and delivery
extension TerminalOffscreenStartupTests {
    func testColdSocketInputQueuesInsteadOfDroppingWhenRuntimeSurfaceIsMissing() {
        let panel = TerminalPanel(workspaceId: UUID())

        panel.surface.releaseSurfaceForTesting()
        XCTAssertNil(panel.surface.surface)
        panel.surface.sendInput("touch /tmp/cmux-cold-send\n")

        let pending = panel.surface.debugPendingSocketInputForTesting()
        XCTAssertGreaterThan(
            pending.items,
            0,
            "Socket input sent before runtime surface creation must be queued or the caller must receive an error."
        )
        XCTAssertGreaterThan(pending.bytes, 0)
    }

    func testColdSocketInputRejectsOversizedQueueInsteadOfDroppingExistingInput() {
        let panel = TerminalPanel(workspaceId: UUID())

        panel.surface.releaseSurfaceForTesting()
        XCTAssertTrue(panel.surface.sendInput("echo keep-me\n"))

        let oversizedInput = String(repeating: "x", count: 1_100_000)
        XCTAssertFalse(
            panel.surface.sendInput(oversizedInput),
            "Cold socket input that cannot fit in the pending queue must be rejected instead of evicting previously accepted input."
        )

        let pending = panel.surface.debugPendingSocketInputForTesting()
        XCTAssertGreaterThan(pending.items, 0)
        XCTAssertLessThan(pending.bytes, 1_100_000)
    }

    func testColdSocketInputQueuesBackspaceControlCharacterAsKeyEvent() {
        let panel = TerminalPanel(workspaceId: UUID())

        panel.surface.releaseSurfaceForTesting()
        XCTAssertTrue(panel.surface.sendInput("abc\u{08}"))

        let pending = panel.surface.debugPendingSocketInputForTesting()
        XCTAssertGreaterThan(
            pending.keyEvents,
            0,
            "Backspace control input must be queued as a key event for cold terminals instead of being pasted as literal text."
        )
    }

    func testColdSocketInputQueuesReturnAsCommittedTextInputInsteadOfPasteOrKeyEvent() {
        let panel = TerminalPanel(workspaceId: UUID())

        panel.surface.releaseSurfaceForTesting()
        XCTAssertTrue(panel.surface.sendInput("printf 'ok\\n'\n"))

        let pending = panel.surface.debugPendingSocketInputForTesting()
        XCTAssertGreaterThan(pending.items, 0)
        XCTAssertGreaterThan(
            pending.inputTextItems,
            0,
            "Programmatic newline input must use Ghostty committed text input so headless mobile commands execute."
        )
        XCTAssertEqual(
            pending.pasteTextItems,
            0,
            "Programmatic newline input must not use paste mode because bracketed paste can strand commands at the prompt."
        )
        XCTAssertEqual(
            pending.keyEvents,
            0,
            "Programmatic newline input must not be translated to Return key events for cold terminals."
        )
    }

    /// Verifies OSC 11 is queued as terminal output bytes instead of literal shell input.
    func testColdSocketInputQueuesOSC11AsRawTerminalBytes() {
        let panel = TerminalPanel(workspaceId: UUID())

        panel.surface.releaseSurfaceForTesting()
        let osc11 = "\u{1B}]11;#341c1c\u{1B}\\"
        XCTAssertTrue(panel.surface.sendInput(osc11))

        let pending = panel.surface.debugPendingSocketInputForTesting()
        XCTAssertEqual(
            pending.keyEvents,
            0,
            "OSC 11 must not be split into Escape key events plus literal text."
        )
        XCTAssertEqual(
            pending.inputTextItems,
            0,
            "OSC 11 must bypass committed text input so Ghostty consumes it as a terminal control sequence."
        )
        XCTAssertEqual(
            pending.pasteTextItems,
            0,
            "OSC 11 must bypass paste input so it is not echoed by the shell."
        )
        XCTAssertEqual(
            pending.processOutputItems,
            1,
            "OSC 11 must be queued as one terminal output payload."
        )
        XCTAssertEqual(pending.bytes, osc11.utf8.count)
    }

    func testColdSocketInputChunksLongCommittedTextInput() {
        let panel = TerminalPanel(workspaceId: UUID())

        panel.surface.releaseSurfaceForTesting()
        let command = "printf '" + String(repeating: "x", count: 360) + "'\n"
        XCTAssertTrue(panel.surface.sendInput(command))

        let pending = panel.surface.debugPendingSocketInputForTesting()
        XCTAssertGreaterThan(
            pending.inputTextItems,
            1,
            "Long programmatic input must be split into committed-text chunks so Ghostty does not drop the tail of the command."
        )
        XCTAssertEqual(pending.pasteTextItems, 0)
        XCTAssertEqual(pending.keyEvents, 0)
        XCTAssertEqual(pending.bytes, command.utf8.count)
    }

    func testTeardownClosesHeadlessStartupWindow() {
        let panel = TerminalPanel(
            workspaceId: UUID(),
            initialCommand: "echo startup"
        )
        XCTAssertTrue(panel.surface.debugHasHeadlessStartupWindowForTesting())

        panel.surface.teardownSurface()

        XCTAssertFalse(
            panel.surface.debugHasHeadlessStartupWindowForTesting(),
            "Explicit terminal teardown should close the hidden bootstrap window immediately instead of waiting for deinit."
        )
    }

    func testClosedSurfaceRejectsColdSocketInputInsteadOfQueueingIt() {
        let panel = TerminalPanel(workspaceId: UUID())

        panel.surface.releaseSurfaceForTesting()
        panel.surface.beginPortalCloseLifecycle(reason: "test.closed")

        XCTAssertFalse(panel.surface.sendInput("echo should-not-queue\n"))
        XCTAssertEqual(
            panel.surface.sendInputResult("echo should-not-queue\n"),
            .surfaceUnavailable
        )
        XCTAssertEqual(panel.surface.sendNamedKey("enter"), .surfaceUnavailable)

        let pending = panel.surface.debugPendingSocketInputForTesting()
        XCTAssertEqual(
            pending.items,
            0,
            "Socket input accepted after terminal lifecycle closure would be stranded because the surface cannot be restarted."
        )
        XCTAssertEqual(pending.bytes, 0)
    }

    func testSendNamedKeyRecognizesCtrlFForceStopChord() {
        // Claude Code (and other raw-tty TUIs) only expose force-stop as a Ctrl-F
        // keybinding. cmux must be able to deliver that chord to the focused terminal
        // via a non-keyboard path, so the named-key layer has to recognize "ctrl-f".
        // A recognized-but-undeliverable key returns `.surfaceUnavailable` on a closed
        // surface, whereas an unrecognized key returns `.unknownKey`.
        let panel = TerminalPanel(workspaceId: UUID())
        panel.surface.releaseSurfaceForTesting()
        panel.surface.beginPortalCloseLifecycle(reason: "test.closed")

        XCTAssertEqual(
            panel.surface.sendNamedKey("ctrl-f"),
            .surfaceUnavailable,
            "ctrl-f must be a recognized control chord so it can be forwarded to the focused terminal."
        )
        XCTAssertEqual(
            panel.surface.sendNamedKey("ctrl+f"),
            .surfaceUnavailable,
            "The ctrl+f alias must resolve identically to ctrl-f."
        )
        XCTAssertEqual(
            panel.surface.sendNamedKey("ctrl-thisisnotakey"),
            .unknownKey,
            "An unrecognized chord must surface as .unknownKey, proving the ctrl-f result is meaningful."
        )
    }

    func testNamedKeySendResultAcceptedReflectsDelivery() {
        // `sendCtrlFToFocusedTerminal()` reports success from this flag, so delivery and
        // failure cases must map correctly.
        XCTAssertTrue(TerminalSurface.NamedKeySendResult.sent.accepted)
        XCTAssertTrue(TerminalSurface.NamedKeySendResult.queued.accepted)
        XCTAssertFalse(TerminalSurface.NamedKeySendResult.unknownKey.accepted)
        XCTAssertFalse(TerminalSurface.NamedKeySendResult.inputQueueFull.accepted)
        XCTAssertFalse(TerminalSurface.NamedKeySendResult.surfaceUnavailable.accepted)
        XCTAssertFalse(TerminalSurface.NamedKeySendResult.processExited.accepted)
    }

    func testDaemonSendWorkspaceQueuesColdControlInputInsteadOfReportingDroppedOK() throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panel = try XCTUnwrap(workspace.focusedTerminalPanel)
        panel.surface.releaseSurfaceForTesting()
        XCTAssertNil(panel.surface.surface)

        let response = TerminalController.shared.handleSocketLine(
            "send_workspace \(workspace.id.uuidString) touch /tmp/cmux-daemon-cold-send\\n"
        )
        XCTAssertEqual(response, "OK")
        TerminalMutationBus.shared.drainForTesting()

        let pending = panel.surface.debugPendingSocketInputForTesting()
        XCTAssertGreaterThan(pending.items, 0)
        XCTAssertGreaterThan(
            pending.inputTextItems,
            0,
            "A daemon send that accepts newline input for a cold terminal must queue committed text input instead of reporting OK for pasted text that can fail to execute."
        )
        XCTAssertEqual(pending.pasteTextItems, 0)
        XCTAssertEqual(pending.keyEvents, 0)
    }

}
