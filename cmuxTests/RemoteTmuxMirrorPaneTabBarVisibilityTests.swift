import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized) struct RemoteTmuxMirrorPaneTabBarVisibilityTests {
    /// A mirrored pane is one tmux pane, so its tab bar can never gain a second tab. In a
    /// single-pane window that bar sits directly under the workspace tab and repeats its
    /// title, which reads as two stacked tab bars.
    @Test("a single-pane mirror window hides its pane tab bar")
    func singlePaneMirrorWindowHidesPaneTabBar() throws {
        let harness = try RemoteTmuxSessionMirrorLayoutHarness()
        defer { harness.tearDown() }

        let mirror = try #require(harness.windowMirror)
        #expect(mirror.paneIDsInOrder.count == 1)
        #expect(mirror.bonsplitController.configuration.tabBarVisibility == .multipleTabs)
    }

    /// Splitting is what gives the bars something to say: which pane is which, and the close
    /// and split buttons for each.
    @Test("splitting a mirror window shows the pane tab bars, and closing back to one hides them")
    func splittingShowsPaneTabBarsAndClosingHidesThem() throws {
        let harness = try RemoteTmuxSessionMirrorLayoutHarness()
        defer { harness.tearDown() }

        let mirror = try #require(harness.windowMirror)
        #expect(mirror.bonsplitController.configuration.tabBarVisibility == .multipleTabs)

        try harness.publishLayout(
            "abcd,80x24,0,0[80x12,0,0,11,80x11,0,13,22]",
            rects: [
                "%11 0 0 80 12 1 off :zsh",
                "%22 0 13 80 11 0 off :zsh",
            ]
        )
        #expect(mirror.paneIDsInOrder.count == 2)
        #expect(mirror.bonsplitController.configuration.tabBarVisibility == .always)

        // A pane can also disappear without cmux asking — it exits on its own, or another
        // client kills it — and both arrive as a layout, so the bars have to go back.
        try harness.publishLayout(
            "f92f,80x24,0,0,11",
            rects: ["%11 0 0 80 24 1 off :zsh"]
        )
        #expect(mirror.paneIDsInOrder.count == 1)
        #expect(mirror.bonsplitController.configuration.tabBarVisibility == .multipleTabs)
    }
}
