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
    /// Window-construction coverage for the modern Settings chrome contract
    /// (https://github.com/manaflow-ai/cmux/issues/8010).
    @MainActor
    @Suite(.serialized)
    struct SettingsWindowChromeTests {
        @Test func factoryBuildsModernUnifiedChromeWithNativeSidebarToolbar() throws {
            let window = SettingsWindowFactory.makeSettingsWindow(onContentAppear: {})
            defer {
                window.orderOut(nil)
                window.contentViewController = nil
                window.contentView = nil
                window.close()
            }

            #expect(window.styleMask.contains(.fullSizeContentView))
            #expect(window.toolbarStyle == .unifiedCompact)
            #expect(window.titlebarAppearsTransparent)
            #expect(window.titleVisibility == .hidden)
            #expect(window.titlebarSeparatorStyle == .none)

            let hostingController = try #require(
                window.contentViewController as? NSHostingController<SettingsWindowHostRoot>
            )
            #expect(hostingController.sceneBridgingOptions.contains(.toolbars))
            #expect(hostingController.sceneBridgingOptions.contains(.title))

            // Toolbar bridging is only observable after the hosting controller
            // is attached to a live window. Require the NavigationSplitView's
            // native sidebar item and exercise its responder-chain action so a
            // bare option bit cannot satisfy this regression test.
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderBack(nil)
            window.contentView?.layoutSubtreeIfNeeded()

            let toolbar = try #require(window.toolbar)
            let sidebarToggle = try #require(
                toolbar.items.first {
                    $0.action == #selector(NSSplitViewController.toggleSidebar(_:))
                }
            )
            let action = try #require(sidebarToggle.action)
            let splitViewController = try #require(
                NSApp.target(
                    forAction: action,
                    to: sidebarToggle.target,
                    from: sidebarToggle
                ) as? NSSplitViewController
            )
            let sidebarItem = try #require(
                splitViewController.splitViewItems.first { $0.behavior == .sidebar }
            )
            let wasCollapsed = sidebarItem.isCollapsed

            #expect(sidebarToggle.isEnabled)
            var handled = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                handled = NSApp.sendAction(action, to: sidebarToggle.target, from: sidebarToggle)
            }
            #expect(handled)
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(sidebarItem.isCollapsed != wasCollapsed)
        }
    }
}
#endif
