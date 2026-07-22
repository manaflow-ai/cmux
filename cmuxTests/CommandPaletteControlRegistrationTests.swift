import AppKit
import CmuxCommandPalette
import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CommandPaletteControlRegistrationTests {
    @Test func registrationDoesNotPublishSocketControlBeforeItsHandlerExists() {
        let appDelegate = AppDelegate()
        let tabManager = TabManager()
        let windowID = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            window.close()
        }

        let didPublishControl = appDelegate.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: tabManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )

        #expect(!didPublishControl)
        #expect(appDelegate.mainWindowContext(for: tabManager)?.commandPaletteControlHandler == nil)
    }

    @Test func registeredWindowPublishesItsHandlerWithItsRoutingContext() {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager()
        let item = CommandPaletteControlRequestItem(
            id: "palette.fixture",
            title: "Fixture",
            subtitle: "Tests",
            shortcutHint: nil,
            keywords: ["fixture"],
            dismissOnRun: true,
            arguments: []
        )
        let windowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: tabManager,
            commandPaletteControlHandler: { request in
                request.complete(.listed([item]))
            }
        )
        AppDelegate.shared = appDelegate
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousAppDelegate
        }

        let resolution = TerminalController.shared.controlCommandPaletteList(
            routing: ControlRoutingSelectors(
                hasWindowIDParam: true,
                windowID: windowID,
                groupID: nil,
                workspaceID: nil,
                surfaceID: nil,
                paneID: nil
            )
        )

        #expect(resolution == .listed(
            windowID: windowID,
            commands: [
                ControlCommandPaletteItem(
                    id: "palette.fixture",
                    title: "Fixture",
                    subtitle: "Tests",
                    shortcutHint: nil,
                    keywords: ["fixture"],
                    dismissOnRun: true
                ),
            ]
        ))
    }
}
