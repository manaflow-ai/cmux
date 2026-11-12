import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AppDelegateEqualizeSplitsShortcutTests {
    @Test
    func testDividerDoubleClickEqualizesContainingSplitRun() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let appDelegate = try #require(AppDelegate.shared)
            let defaults = UserDefaults.standard
            let key = "equalizeSplitsOnDividerDoubleClick"
            let saved = defaults.object(forKey: key)
            defer {
                if let saved { defaults.set(saved, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            for orientation in [SplitOrientation.horizontal, .vertical] {
                let windowId = appDelegate.createMainWindow()
                defer { self.closeWindow(withId: windowId) }
                let window = try #require(self.window(withId: windowId))
                let workspace = try #require(appDelegate.tabManagerFor(windowId: windowId)?.selectedWorkspace)
                Self.prepareSplitFixture(window: window, workspace: workspace)
                let first = try #require(workspace.focusedPanelId)
                let cross: SplitOrientation = orientation == .horizontal ? .vertical : .horizontal
                let other = try #require(workspace.newTerminalSplit(from: first, orientation: cross))
                let second = try #require(workspace.newTerminalSplit(from: first, orientation: orientation))
                _ = try #require(workspace.newTerminalSplit(from: second.id, orientation: orientation))
                let controller = workspace.bonsplitController
                let nodes = self.shortcutRoutingSplitNodes(in: controller.treeSnapshot())
                for node in nodes {
                    #expect(controller.setDividerPosition(0.25, forSplit: try #require(UUID(uuidString: node.id))))
                }
                let axis = orientation == .horizontal ? "horizontal" : "vertical"
                let clicked = try #require(nodes.last { $0.orientation == axis })
                let splitId = try #require(UUID(uuidString: clicked.id))
                let untouched = try #require(nodes.first { $0.orientation != axis })
                let panes = controller.allPaneIds
                let tabs = controller.allTabIds
                controller.focusPane(try #require(workspace.paneId(forPanelId: other.id)))
                let delegate: any BonsplitDelegate = workspace
                defaults.set(false, forKey: key)
                #expect(!delegate.splitTabBar(controller, didDoubleClickDivider: splitId))
                #expect(self.shortcutRoutingSplitNodes(in: controller.treeSnapshot()).allSatisfy {
                    abs($0.dividerPosition - 0.25) < 0.0001
                })
                defaults.removeObject(forKey: key)
                #expect(!delegate.splitTabBar(BonsplitController(), didDoubleClickDivider: splitId))
                #expect(!delegate.splitTabBar(controller, didDoubleClickDivider: UUID()))
                workspace.isRemoteTmuxMirror = true
                #expect(!delegate.splitTabBar(controller, didDoubleClickDivider: splitId))
                workspace.isRemoteTmuxMirror = false
                #expect(delegate.splitTabBar(controller, didDoubleClickDivider: splitId))
                let result = self.shortcutRoutingSplitNodes(in: controller.treeSnapshot())
                #expect(result.first { $0.id == untouched.id }?.dividerPosition == 0.25)
                let run = result.filter { $0.orientation == axis }
                #expect(run.count == 2)
                #expect(abs(try #require(run.first).dividerPosition - 1.0 / 3.0) < 0.0001)
                #expect(run.last?.dividerPosition == 0.5)
                #expect(controller.allPaneIds == panes)
                #expect(controller.allTabIds == tabs)
                let published = await self.shortcutRoutingAwaitPublishedLayout(workspace) {
                    $0.panes == controller.layoutSnapshot().panes
                }
                #expect(published != nil)
            }
        }
    }
}
