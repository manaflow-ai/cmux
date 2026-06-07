import AppKit
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Regression coverage for the close-shortcut routing of the iOS pairing
/// ("Sign In") window.
///
/// The pairing window hosts a standalone sign-in / pairing flow. Pressing Cmd-W
/// (or choosing menu Close) while it is key must dismiss the pairing window
/// itself, never the workspace window behind it. The routing decision lives in
/// ``cmuxWindowShouldOwnCloseShortcut(_:)``: it returns `true` for auxiliary
/// windows (whose own `performClose:` runs) and `false` for the main workspace
/// window (where Cmd-W falls through to panel/workspace close). Before the fix
/// the pairing window's identifier was missing from the auxiliary set, so the
/// shortcut closed the workspace behind it.
@MainActor
@Suite struct MobilePairingWindowCloseRoutingTests {
    private func makeWindow(identifier: String?) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        if let identifier {
            window.identifier = NSUserInterfaceItemIdentifier(identifier)
        }
        return window
    }

    @Test func pairingWindowOwnsItsCloseShortcut() {
        let window = makeWindow(identifier: MobilePairingWindowController.windowIdentifier)
        #expect(cmuxWindowShouldOwnCloseShortcut(window) == true)
    }

    @Test func mainWorkspaceWindowDoesNotOwnCloseShortcut() {
        // The main workspace window must NOT own the shortcut, so Cmd-W keeps
        // routing to panel/workspace close instead of closing the whole window.
        let window = makeWindow(identifier: "cmux.mainWindow")
        #expect(cmuxWindowShouldOwnCloseShortcut(window) == false)
    }

    @Test func windowWithoutIdentifierDoesNotOwnCloseShortcut() {
        let window = makeWindow(identifier: nil)
        #expect(cmuxWindowShouldOwnCloseShortcut(window) == false)
    }

    @Test func nilWindowDoesNotOwnCloseShortcut() {
        #expect(cmuxWindowShouldOwnCloseShortcut(nil) == false)
    }
}
