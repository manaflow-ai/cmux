import AppKit
import Bonsplit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Workspace title bar layout", .serialized)
struct WorkspaceTitlebarLayoutTests {
    @Test(arguments: [false, true], [CGFloat(0), CGFloat(28)])
    func hiddenTitleOnlyCancelsTheHostingInset(isFullScreen: Bool, safeArea: CGFloat) {
        for minimalMode in [false, true] {
            #expect(ContentView.effectiveTitlebarPadding(
                isMinimalMode: minimalMode,
                showWorkspaceTitleBar: false,
                isFullScreen: isFullScreen,
                titlebarPadding: 32,
                hostingSafeAreaTop: safeArea
            ) == (isFullScreen ? 0 : -safeArea))
        }
        #expect(ContentView.effectiveTitlebarPadding(
            isMinimalMode: false,
            showWorkspaceTitleBar: true,
            isFullScreen: isFullScreen,
            titlebarPadding: 32,
            hostingSafeAreaTop: safeArea
        ) == WindowChromeMetrics.appTitlebarHeight)
    }

    /// Uses real Bonsplit tab strips and the production title/padding modifiers.
    /// Panel placeholders isolate layout from terminal processes and WebKit.
    @Test(arguments: [1, 3], [false, true])
    func titleToggleReclaimsSpaceWithoutRemovingPaneTabs(tabCount: Int, split: Bool) async throws {
        let fixture = try WorkspaceTitlebarLayoutFixture(tabCount: tabCount, split: split)
        defer { fixture.close() }
        await fixture.layout()
        let before = try fixture.panelFrame()
        #expect(fixture.hasTitle)
        #expect(abs(before.minY - WindowChromeMetrics.appTitlebarHeight - WindowChromeMetrics.bonsplitTabBarHeight) < 1)

        fixture.defaults.set(false, forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        await fixture.layout()
        let hidden = try fixture.panelFrame()
        #expect(!fixture.hasTitle)
        #expect(abs(before.minY - hidden.minY - WindowChromeMetrics.appTitlebarHeight) < 1)
        #expect(abs(hidden.minY - WindowChromeMetrics.bonsplitTabBarHeight) < 1)
        #expect(fixture.controller.tabs(inPane: fixture.terminalPane).count == tabCount)
        if split {
            let browser = try fixture.panelFrame(identifier: "Browser")
            #expect(abs(browser.minY - hidden.minY) < 1)
            #expect(browser.minX > hidden.minX)
        }
        if let first = fixture.controller.tabs(inPane: fixture.terminalPane).first {
            fixture.controller.selectTab(first.id)
            await fixture.layout()
            #expect(fixture.controller.selectedTab(inPane: fixture.terminalPane)?.id == first.id)
            #expect(abs(try fixture.panelFrame().minY - hidden.minY) < 1)
        }

        fixture.defaults.set(true, forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        await fixture.layout()
        #expect(fixture.hasTitle)
        #expect(abs(try fixture.panelFrame().minY - before.minY) < 1)
        fixture.defaults.set("minimal", forKey: WorkspacePresentationModeSettings.modeKey)
        await fixture.layout()
        #expect(!fixture.hasTitle)
        #expect(abs(try fixture.panelFrame().minY - hidden.minY) < 1)
        fixture.defaults.set("standard", forKey: WorkspacePresentationModeSettings.modeKey)
        await fixture.layout()
        #expect(fixture.hasTitle)
    }
}
