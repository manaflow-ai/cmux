import AppKit
import CmuxAppKitSupportUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct TitlebarAccessoryVisibilityTests {
    @Test
    func fullscreenAndMinimalModeUpdateBothSidebarAccessories() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer {
            for index in window.titlebarAccessoryViewControllers.indices.reversed() {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            window.orderOut(nil)
        }
        let sidebarAccessories = ["cmux.titlebarControls", "cmux.rightSidebarTitlebarToggle"].map {
            Self.addAccessory(identifier: $0, to: window)
        }
        let unrelatedAccessory = Self.addAccessory(identifier: "unrelated", to: window)
        let chrome = AppWindowChromeComposition(fullscreenAuxiliaryWindows: { [] })

        // Exercise the same callback used by ContentView's fullscreen and
        // presentation-mode notifications, without a key/main-window change.
        for (fullscreen, minimal) in [
            (true, false), (false, false), (false, true),
            (true, true), (false, true), (false, false)
        ] {
            chrome.nativeTitlebarBackdropCoordinator.setTitlebarControlsHidden(
                fullscreen,
                in: window,
                isMinimalMode: minimal
            )
            let shouldHide = fullscreen || minimal
            for accessory in sidebarAccessories {
                #expect(accessory.isHidden == shouldHide)
                #expect(accessory.view.isHidden == shouldHide)
                #expect(accessory.view.alphaValue == (shouldHide ? 0 : 1))
            }
            #expect(!unrelatedAccessory.isHidden)
            #expect(!unrelatedAccessory.view.isHidden)
            #expect(unrelatedAccessory.view.alphaValue == 1)
        }
    }

    private static func addAccessory(
        identifier: String,
        to window: NSWindow
    ) -> NSTitlebarAccessoryViewController {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = NSView(frame: NSRect(x: 0, y: 0, width: 30, height: 28))
        accessory.view.identifier = NSUserInterfaceItemIdentifier(identifier)
        accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)
        return accessory
    }
}
