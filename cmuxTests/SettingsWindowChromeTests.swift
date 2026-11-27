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

    /// Records that the observed Settings command notification was delivered.
    func set() { isSet = true }
}

@MainActor
/// Waits for the Settings host root to report that its content is mounted.
private final class SettingsChromeReadiness {
    private var isReady = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Resolves all tests waiting for the first content appearance.
    func signal() {
        guard !isReady else { return }
        isReady = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }

    /// Suspends until the hosted Settings content has appeared.
    func wait() async {
        guard !isReady else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

extension SettingsWindowSharedStateSuites {
    /// Window-construction coverage for the native Settings chrome contract:
    /// the structure the SwiftUI-owned `WindowGroup` scene produced (full-
    /// height sidebar, sidebar toggle, leading title) on top of the reliable
    /// AppKit-owned lifecycle from #7783.
    @MainActor
    @Suite(.serialized)
    struct SettingsWindowChromeTests {
        /// Verifies the AppKit-owned window preserves the native Settings chrome contract.
        @Test func presenterBuildsNativeSplitViewChrome() async throws {
            closeSettingsWindows()
            defer { closeSettingsWindows() }

            let readiness = SettingsChromeReadiness()
            let presenter = SettingsWindowPresenter { _ in
                SettingsWindowFactory.makeSettingsWindow(onContentAppear: readiness.signal)
            }
            try #require(presenter.show() == .presented)
            await readiness.wait()
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

            // AppKit owns the Settings window's geometry and chrome. Keeping
            // SwiftUI out of NSHostingController's scene/window bridge avoids
            // the macOS 27 construction-time layout recursion that overflowed
            // the main-thread stack (CMUXTERM-MACOS-27J7).
            #expect(window.contentViewController == nil)
            #expect(window.contentView is NSHostingView<SettingsWindowHostRoot>)

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

        /// Verifies the toolbar button routes through the shared sidebar command notification.
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

        /// Closes all Settings windows and clears their saved frame for test isolation.
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
