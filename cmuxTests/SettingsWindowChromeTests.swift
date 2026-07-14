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
        @Test func presenterBuildsNative06417ChromeWithSwiftUISceneBridge() throws {
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
            // The app-host CI harness does not materialize bridged SwiftUI
            // scene items in NSWindow.toolbar, even for this real key-window
            // presenter path (Actions run 29313630434). Keep the deterministic
            // public bridge contract here; the native item needs visual proof.
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
