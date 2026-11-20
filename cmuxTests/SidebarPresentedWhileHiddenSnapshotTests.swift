import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The floating peek card is a second `VerticalTabsSidebar` that is presented
/// while the window's docked sidebar is hidden (`sidebarState.isVisible ==
/// false`). Its rows must keep tracking live workspace state there: a rename
/// committed inline in the card used to persist without ever repainting the
/// card, because the snapshot refresh was gated on the window's docked
/// visibility instead of the instance's own presentation.
@Suite(.serialized)
final class SidebarPresentedWhileHiddenSnapshotTests {
    @Test
    @MainActor
    func renameRefreshesSnapshotsOfAnInstancePresentedWhileTheSidebarIsHidden() async throws {
        let harness = try await SidebarLazyLayoutScaleTests.mountSidebar(
            workspaceCount: 4,
            includeGroups: false,
            sidebarState: SidebarState(isVisible: false)
        )
        defer { harness.tearDown() }

        await SidebarLazyLayoutScaleTests.drainUntilRowWorkQuiesces(
            for: harness.window,
            counter: harness.counter
        )
        #expect(
            harness.counter.workspaceSnapshotBuilds > 0,
            "The presented instance never built its initial snapshots; the probe wiring is broken."
        )
        await SidebarLazyLayoutScaleTests.drainMainRunLoop(for: harness.window)

        harness.counter.reset()
        let workspace = try #require(harness.tabManager.tabs.last)
        #expect(harness.tabManager.setCustomTitle(tabId: workspace.id, title: "Renamed in card"))

        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while harness.counter.workspaceSnapshotBuilds == 0,
              ProcessInfo.processInfo.systemUptime < deadline {
            SidebarLazyLayoutScaleTests.turnMainRunLoopOnce(layingOut: harness.window)
            await Task.yield()
        }
        #expect(
            harness.counter.workspaceSnapshotBuilds > 0,
            """
            A rename did not rebuild the workspace snapshot of a sidebar instance that is \
            presented while the docked sidebar is hidden, so the floating card keeps \
            painting the old title until the sidebar is docked again.
            """
        )
    }
}
