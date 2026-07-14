import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
extension SettingsWindowSharedStateSuites {
    /// Window-construction coverage for the native Settings chrome contract
    /// shipped in cmux 0.64.17, plus the reliable AppKit-owned lifecycle.
    @MainActor
    @Suite(.serialized)
    struct SettingsWindowChromeTests {
        @Test func presenterBuildsNative06417ChromeWithSidebarToolbar() throws {
            closeSettingsWindows()
            defer { closeSettingsWindows() }

            let presenter = SettingsWindowPresenter()
            #expect(presenter.show() == .presented)
            let window = try #require(
                NSApp.windows.first {
                    $0.identifier?.rawValue == SettingsWindowPresenter.windowIdentifier && $0.isVisible
                }
            )

            // #8015 forced a full-size transparent titlebar, removed the
            // native separator, and imposed compact toolbar styling. That
            // produced a hybrid that did not match the SwiftUI-owned window
            // shipped in 0.64.17. Keep AppKit lifecycle ownership, but let
            // the bridged NavigationSplitView supply the standard chrome.
            #expect(!window.styleMask.contains(.fullSizeContentView))
            #expect(window.toolbarStyle == .automatic)
            #expect(!window.titlebarAppearsTransparent)
            #expect(window.titlebarSeparatorStyle == .automatic)

            let hostingController = try #require(
                window.contentViewController as? NSHostingController<SettingsWindowHostRoot>
            )
            #expect(hostingController.sceneBridgingOptions.contains(.toolbars))
            #expect(hostingController.sceneBridgingOptions.contains(.title))

            // The scene bridge installs toolbar content after the real
            // presenter makes the Settings window key. Pump the main run loop
            // until that public AppKit action appears instead of forcing a
            // re-entrant NSHostingView layout pass.
            let sidebarToggle = try #require(waitForNativeSidebarToggle(in: window))
            let action = try #require(sidebarToggle.action)
            #expect(action == #selector(NSSplitViewController.toggleSidebar(_:)))
            #expect(sidebarToggle.isEnabled)
            #expect(NSApp.sendAction(action, to: sidebarToggle.target, from: sidebarToggle))
        }

        private func waitForNativeSidebarToggle(
            in window: NSWindow,
            timeout: TimeInterval = 2
        ) -> NSToolbarItem? {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                if let item = window.toolbar?.items.first(where: {
                    $0.action == #selector(NSSplitViewController.toggleSidebar(_:))
                }) {
                    return item
                }
                _ = RunLoop.main.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.01)
                )
            } while Date() < deadline
            return nil
        }

        private func closeSettingsWindows() {
            for window in NSApp.windows
            where window.identifier?.rawValue == SettingsWindowPresenter.windowIdentifier {
                window.orderOut(nil)
                window.identifier = nil
                window.close()
            }
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame cmux.settings")
        }
    }
}
#endif
