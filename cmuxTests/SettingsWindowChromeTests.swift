import AppKit
import CmuxSettingsUI
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
/// Marks receipt of a synchronously-posted main-thread notification. File
/// scope keeps it out of the suite's @MainActor isolation so the observer's
/// @Sendable block can call it. (A captured `var` can't be mutated there.)
private final class SettingsChromeNotificationFlag: @unchecked Sendable {
    private(set) var isSet = false
    func set() { isSet = true }
}

extension SettingsWindowSharedStateSuites {
    /// Window-construction coverage for the native Settings chrome contract:
    /// the structure the SwiftUI-owned `WindowGroup` scene produced (full-
    /// height sidebar, sidebar toggle, leading title) on top of the reliable
    /// AppKit-owned lifecycle from #7783.
    @MainActor
    @Suite(.serialized)
    struct SettingsWindowChromeTests {
        @Test func presenterBuildsNativeSplitViewChrome() throws {
            closeSettingsWindows()
            defer { closeSettingsWindows() }

            let presenter = SettingsWindowPresenter()
            #expect(presenter.show() == .presented)
            let window = try #require(
                NSApp.windows.first {
                    $0.identifier?.rawValue == SettingsWindowPresenter.windowIdentifier && $0.isVisible
                }
            )

            // Empirically (probe app on macOS 26), a SwiftUI-owned
            // `WindowGroup` window hosting a NavigationSplitView gets
            // `.fullSizeContentView` — required for the sidebar to extend
            // under the titlebar — while the titlebar stays at the AppKit
            // defaults: visible title, opaque titlebar, automatic toolbar
            // style and separator. #8015 diverged by forcing a transparent
            // titlebar, hidden title, no separator, and compact toolbar
            // styling; the follow-up revert overshot by dropping
            // `.fullSizeContentView` too. Pin the exact SwiftUI-owned set.
            #expect(window.styleMask.contains(.fullSizeContentView))
            #expect(window.toolbarStyle == .automatic)
            #expect(!window.titlebarAppearsTransparent)
            #expect(window.titleVisibility == .visible)
            #expect(window.titlebarSeparatorStyle == .automatic)

            // Only the title is scene-bridged. `.toolbars` must stay off:
            // the bridge never materializes NavigationSplitView's implicit
            // sidebar toggle in an AppKit-hosted window (and bridged items
            // don't materialize in the CI harness at all), so the factory
            // owns the toolbar in AppKit, deterministically.
            let hostingController = try #require(
                window.contentViewController as? NSHostingController<SettingsWindowHostRoot>
            )
            #expect(hostingController.sceneBridgingOptions.contains(.title))
            #expect(!hostingController.sceneBridgingOptions.contains(.toolbars))

            // [flexible space, sidebar toggle, sidebar tracking separator]
            // is the exact item layout SwiftUI builds for its own
            // NavigationSplitView window: toggle at the sidebar's trailing
            // edge, bold title at the detail column's leading edge.
            let toolbar = try #require(window.toolbar)
            #expect(
                toolbar.items.map(\.itemIdentifier) == [
                    .flexibleSpace,
                    SettingsSidebarToolbarController.toggleSidebarItemIdentifier,
                    .sidebarTrackingSeparator,
                ]
            )
        }

        @Test func toolbarToggleSharesTheMenuCommandNotificationPath() throws {
            closeSettingsWindows()
            defer { closeSettingsWindows() }

            let presenter = SettingsWindowPresenter()
            #expect(presenter.show() == .presented)
            let window = try #require(
                NSApp.windows.first {
                    $0.identifier?.rawValue == SettingsWindowPresenter.windowIdentifier && $0.isVisible
                }
            )
            let toggleItem = try #require(
                window.toolbar?.items.first {
                    $0.itemIdentifier == SettingsSidebarToolbarController.toggleSidebarItemIdentifier
                }
            )
            #expect(toggleItem.isEnabled)

            // The toolbar button and the Toggle Left Sidebar menu command
            // must share one mutation path: the sidebar-toggle notification
            // that flips `columnVisibility` in SettingsWindowRoot.
            let received = SettingsChromeNotificationFlag()
            let observer = NotificationCenter.default.addObserver(
                forName: SettingsWindowRoot.sidebarToggleRequestName,
                object: nil,
                queue: nil
            ) { _ in received.set() }
            defer { NotificationCenter.default.removeObserver(observer) }

            let action = try #require(toggleItem.action)
            #expect(NSApp.sendAction(action, to: toggleItem.target, from: toggleItem))
            #expect(received.isSet)
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
