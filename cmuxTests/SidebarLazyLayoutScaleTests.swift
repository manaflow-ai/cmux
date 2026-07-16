import Testing
import AppKit
import CmuxUpdater
import OSLog
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral gate for the workspace sidebar's virtualization contract: layout
/// and diff work must stay O(visible rows) no matter how many workspaces are
/// open, and updates must converge (no self-sustaining invalidation).
///
/// The contract regressed five times under SwiftUI through five different
/// mechanisms — per-row anchorPreference aggregation (#5323), per-row String
/// ids (#5764), animated row-height interpolation (#5845), a force-measuring
/// custom Layout (#6210), and GeometryReader → @State row-height feedback
/// (#6556) — each shipping to stable before being detected at the 100+
/// workspace scale where O(N) per pass livelocks the main thread (#2586).
/// The list is now a pure-AppKit `NSTableView`
/// (`SidebarWorkspaceTableController`), so these tests mount the REAL
/// `VerticalTabsSidebar` (which embeds the table representable) at that scale
/// and assert against the table itself: materialized cell counts for
/// virtualization, and the DEBUG `tableRootViewReconfigure` probe for
/// row-scoped update cost and convergence.
@Suite(.serialized)
final class SidebarLazyLayoutScaleTests {
    static let workspaceCount = 300
    /// A 640pt window shows ~20 rows; allow a small AppKit reuse/prefetch
    /// buffer. A virtualization defeat materializes all 300.
    private static let realizedCellCeiling = 80

    // Plain class (not @MainActor) so the probe's nonisolated `() -> Void`
    // closure can mutate it; the closure only runs on the main thread. Same
    // shape as MinimalModeBodyProbeCounts in WorkspaceContentViewVisibilityTests.
    final class ReconfigureCounter {
        var tableCellReconfigures = 0
        var canaryBodies = 0
        func reset() {
            tableCellReconfigures = 0
            canaryBodies = 0
        }
    }

    @MainActor
    struct Harness {
        let tabManager: TabManager
        let unread: SidebarUnreadModel
        let counter: ReconfigureCounter
        let window: NSWindow
        let defaultsSuiteName: String

        func tearDown() {
            window.contentView = nil
            window.close()
            UserDefaults(suiteName: defaultsSuiteName)?
                .removePersistentDomain(forName: defaultsSuiteName)
        }
    }

    @MainActor
    static func mountSidebar(workspaceCount: Int) async throws -> Harness {
        _ = NSApplication.shared

        // Hermetic defaults: VerticalTabsSidebar picks between the workspace
        // list and extension/built-in sidebars via
        // @AppStorage(CmuxExtensionSidebarSelection.defaultsKey). A persisted
        // non-default provider on the host would mount the wrong sidebar and
        // no table would exist. Same pattern as
        // WorkspaceContentViewVisibilityTests.
        let defaultsSuiteName = "SidebarLazyLayoutScaleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults.set(
            CmuxExtensionSidebarSelection.defaultProviderId,
            forKey: CmuxExtensionSidebarSelection.defaultsKey
        )

        let tabManager = TabManager()
        while tabManager.tabs.count < workspaceCount {
            // Per-iteration pool + periodic run-loop turns: the app creates
            // workspaces one per event-loop turn, with AppKit popping the
            // autorelease pool between turns. Creating hundreds inside one
            // main-actor job accumulates every autoreleased object from the
            // O(N) per-add snapshot work into a single pool, and the final
            // objc_autoreleasePoolPop then hangs or crashes the test host
            // (observed as Signal 11 in AutoreleasePoolPage::releaseUntil).
            autoreleasepool {
                _ = tabManager.addWorkspace(
                    select: false,
                    autoWelcomeIfNeeded: false,
                    autoRefreshMetadata: false
                )
            }
            if tabManager.tabs.count % 20 == 0 {
                Self.turnMainRunLoopOnce(layingOut: nil)
                await Task.yield()
            }
        }

        // Group the first workspaces (top of the list, inside the viewport) so
        // group-header rows — a historical regression site (#4385) — are
        // covered by the same materialization bounds.
        let groupCandidates = Array(tabManager.tabs.prefix(20).map(\.id))
        for chunkStart in stride(from: 0, to: groupCandidates.count, by: 4) {
            let children = Array(groupCandidates[chunkStart..<min(chunkStart + 4, groupCandidates.count)])
            _ = tabManager.createWorkspaceGroup(
                name: "Group \(chunkStart / 4)",
                childWorkspaceIds: children,
                selectAnchor: false,
                collapseSidebarSelection: false
            )
        }
        Self.turnMainRunLoopOnce(layingOut: nil)

        let unread = SidebarUnreadModel()
        let counter = ReconfigureCounter()

        let root = VerticalTabsSidebar(
            updateViewModel: UpdateStateModel(),
            fileExplorerState: FileExplorerState(),
            windowId: UUID(),
            onSendFeedback: {},
            onToggleSidebar: {},
            onNewTab: {},
            observedWindow: nil,
            selection: .constant(.tabs),
            selectedTabIds: .constant([]),
            lastSidebarSelectionIndex: .constant(nil),
            sidebarRenderWorkerClient: .constant(nil)
        )
        .frame(width: 280)
        .environmentObject(tabManager)
        .environmentObject(unread)
        .environmentObject(CmuxConfigStore())
        .environmentObject(TerminalNotificationStore.shared)
        .environmentObject(SidebarState())
        .environmentObject(SidebarSelectionState())
        .environment(
            \.sidebarLazyContractProbe,
            SidebarLazyContractProbe(
                tableRootViewReconfigure: { counter.tableCellReconfigures += 1 }
            )
        )
        .defaultAppStorage(defaults)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // ARC owns this window; without this, close() performs AppKit's own
        // release on top of ARC's and the double-release SEGVs the test host
        // at the next autorelease-pool pop (zombies: "-[NSKVONotifying_NSWindow
        // release]: message sent to deallocated instance"). That crash killed
        // the host before the pass was recorded, and CI masked it (#5641).
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)

        return Harness(
            tabManager: tabManager,
            unread: unread,
            counter: counter,
            window: window,
            defaultsSuiteName: defaultsSuiteName
        )
    }

    /// One synchronous run-loop turn. Kept out of the async context so the
    /// `RunLoop.run(_:before:)` call is legal under Swift 6, and wrapped in its
    /// own autorelease pool so drained main-queue work cannot pile objects
    /// into the enclosing job's pool.
    @MainActor
    static func turnMainRunLoopOnce(layingOut window: NSWindow?) {
        autoreleasepool {
            window?.contentView?.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }
    }

    @MainActor
    static func drainMainRunLoop(for window: NSWindow, iterations: Int = 25) async {
        for _ in 0..<iterations {
            Self.turnMainRunLoopOnce(layingOut: window)
            await Task.yield()
        }
    }

    // MARK: - View walking

    @MainActor
    private static func firstDescendant<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        var pending = [root]
        while let view = pending.popLast() {
            if let match = view as? T { return match }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }

    @MainActor
    private static func descendants<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        var result: [T] = []
        var pending = [root]
        while let view = pending.popLast() {
            if let match = view as? T { result.append(match) }
            pending.append(contentsOf: view.subviews)
        }
        return result
    }

    // MARK: - Tests

    /// Mounting the sidebar with 300 workspaces must materialize only the
    /// cells one viewport needs. Materializing all of them is the #5323/#6210
    /// defeat: at scale, every subsequent update pays an O(N) layout pass and
    /// the main thread livelocks.
    @Test
    @MainActor
    func testMountRealizesOnlyViewportCellsAt300Workspaces() async throws {
        let harness = try await Self.mountSidebar(workspaceCount: Self.workspaceCount)
        defer { harness.tearDown() }

        await Self.drainMainRunLoop(for: harness.window)

        let rootView = try #require(harness.window.contentView)
        let table = try #require(
            Self.firstDescendant(SidebarWorkspaceTableViewImpl.self, in: rootView),
            "The AppKit workspace table did not mount inside VerticalTabsSidebar."
        )
        // The full data set is present while the cell count stays viewport-sized.
        #expect(table.numberOfRows >= Self.workspaceCount)

        let workspaceCells = Self.descendants(SidebarWorkspaceTableCellView.self, in: rootView)
        #expect(!workspaceCells.isEmpty, "The table materialized no workspace cells.")
        #expect(
            workspaceCells.count < Self.realizedCellCeiling,
            """
            NSTableView materialized \(workspaceCells.count) workspace cells for a single \
            ~20-row viewport with \(Self.workspaceCount) workspaces. Virtualization is being \
            defeated (all rows realized per pass) — the #2586 sidebar livelock class at scale.
            """
        )

        let headerCells = Self.descendants(SidebarWorkspaceGroupHeaderCellView.self, in: rootView)
        #expect(
            !headerCells.isEmpty,
            """
            Groups were created at the top of the list but no group-header cell \
            materialized; the grouped-workspace coverage is broken.
            """
        )
        #expect(
            headerCells.count < Self.realizedCellCeiling,
            """
            \(headerCells.count) group-header cells materialized for 5 groups in one \
            viewport — the group-header row path is defeating virtualization (the #4385 \
            regression site).
            """
        )

#if DEBUG
        #expect(
            harness.counter.tableCellReconfigures > 0,
            "The table mounted but the tableRootViewReconfigure probe never fired; probe wiring is broken."
        )
#endif
    }

    /// A burst of unread-model updates (the agent-notification churn path, the
    /// sidebar's highest-frequency invalidation) must cost O(changed rows) in
    /// cell reconfigurations, and the table must go quiet when the burst
    /// stops. Unbounded or non-converging reconfiguration here is the exact
    /// signature of the #6556 feedback livelock, expressed against the AppKit
    /// table instead of SwiftUI row bodies.
    @Test
    @MainActor
    func testUnreadStormStaysRowScopedAndConverges() async throws {
        let harness = try await Self.mountSidebar(workspaceCount: Self.workspaceCount)
        defer { harness.tearDown() }

        await Self.drainMainRunLoop(for: harness.window)
        harness.counter.reset()

        let stormTargets = Array(harness.tabManager.tabs.prefix(3).map(\.id))
        let storms = 40
        for i in 1...storms {
            let target = stormTargets[i % stormTargets.count]
            harness.unread.apply(
                totalUnreadCount: i,
                summaries: [
                    target: SidebarWorkspaceUnreadSummary(
                        unreadCount: i,
                        latestNotificationText: "agent update \(i)"
                    )
                ],
                unreadSurfaceKeys: [],
                focusedReadIndicatorByWorkspaceId: [:],
                manualUnreadWorkspaceIds: []
            )
            await Self.drainMainRunLoop(for: harness.window, iterations: 2)
        }
        await Self.drainMainRunLoop(for: harness.window)

#if DEBUG
        let stormReconfigures = harness.counter.tableCellReconfigures
        #expect(
            stormReconfigures > 0,
            "The unread storm reconfigured no cells; the update path or probe wiring is broken."
        )
        #expect(
            stormReconfigures < storms * 10,
            """
            \(stormReconfigures) cell reconfigurations for \(storms) single-workspace unread \
            updates. Each update must reconfigure only the changed visible rows (the changed \
            workspace row and its group header), not the whole viewport per pass — \
            \(Self.workspaceCount) workspaces × \(storms) updates re-realizing per pass is \
            the #2586 livelock at scale.
            """
        )

        harness.counter.reset()
        await Self.drainMainRunLoop(for: harness.window, iterations: 30)
        let quietReconfigures = harness.counter.tableCellReconfigures
        #expect(
            quietReconfigures < 20,
            """
            \(quietReconfigures) cell reconfigurations happened with no state changes at \
            all. The sidebar is re-applying/reconfiguring itself in a loop (the #6556 \
            signature); this livelocks the main thread at scale.
            """
        )
#endif
    }

    /// Churn variable-height content, scroll, and table-owned hover, then
    /// assert the run emitted none of the SwiftUI/AppKit runtime faults that
    /// accompanied every historical sidebar livelock.
    @Test
    @MainActor
    func testTableChurnScrollAndHoverEmitNoRuntimeFaults() async throws {
        let harness = try await Self.mountSidebar(workspaceCount: Self.workspaceCount)
        defer { harness.tearDown() }

        await Self.drainMainRunLoop(for: harness.window)
        let rootView = try #require(harness.window.contentView)
        let table = try #require(Self.firstDescendant(SidebarWorkspaceTableViewImpl.self, in: rootView))
        let logStore = try OSLogStore(scope: .currentProcessIdentifier)
        let start = logStore.position(date: Date())

        for index in 0..<40 {
            let workspace = harness.tabManager.tabs[index % 8]
            harness.tabManager.setCustomTitle(
                tabId: workspace.id,
                title: String(repeating: "variable title \(index) ", count: (index % 5) + 1)
            )
            harness.unread.apply(
                totalUnreadCount: index + 1,
                summaries: [
                    workspace.id: SidebarWorkspaceUnreadSummary(
                        unreadCount: index + 1,
                        latestNotificationText: String(repeating: "update ", count: (index % 4) + 1)
                    )
                ],
                unreadSurfaceKeys: [],
                focusedReadIndicatorByWorkspaceId: [:],
                manualUnreadWorkspaceIds: []
            )
            table.scrollRowToVisible((index * 17) % Self.workspaceCount)
            table.setPointerWindowLocation(table.convert(
                NSPoint(x: 20, y: table.visibleRect.midY),
                to: nil
            ))
            await Self.drainMainRunLoop(for: harness.window, iterations: 2)
        }
        table.setPointerWindowLocation(nil)
        await Self.drainMainRunLoop(for: harness.window, iterations: 30)

        let faultNeedles = ["Modifying state during view update",
                            "Publishing changes from within view updates",
                            "laid out reentrantly"]
        let faults = try logStore.getEntries(at: start).compactMap { entry -> String? in
            guard let log = entry as? OSLogEntryLog else { return nil }
            return faultNeedles.contains { log.composedMessage.localizedCaseInsensitiveContains($0) }
                ? log.composedMessage : nil
        }
        #expect(faults.isEmpty, "Sidebar churn emitted runtime faults: \(faults)")
    }

    /// Harness self-test: prove the drain loop + counter actually detect a
    /// non-converging invalidation loop. This fixture reproduces the
    /// historical GeometryReader → @State row-height shape (#6556) in
    /// divergent form; if the harness cannot flag THIS, the convergence
    /// assertions above are vacuous.
    @Test
    @MainActor
    func testHarnessDetectsGeometryFeedbackLoopCanary() async throws {
        _ = NSApplication.shared

        let counter = ReconfigureCounter()
        let rows = 8
        let root = VStack(spacing: 2) {
            ForEach(0..<rows, id: \.self) { _ in
                DivergentGeometryFeedbackRowFixture(onBody: { counter.canaryBodies += 1 })
            }
        }
        .frame(width: 200)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }
        window.contentView = NSHostingView(rootView: root)

        await Self.drainMainRunLoop(for: window, iterations: 40)

        #expect(
            counter.canaryBodies > rows * 3,
            """
            The divergent GeometryReader → @State fixture only produced \
            \(counter.canaryBodies) body evaluations for \(rows) rows; the harness can no \
            longer observe layout feedback loops, so the convergence tests above are not \
            protecting anything. Fix the harness before trusting them.
            """
        )
    }
}

/// Reproduces the #6556 anti-pattern in deliberately divergent form: a
/// GeometryReader writes measured height back into `@State` that feeds the
/// row's own frame, so every layout pass invalidates the next. Test fixture
/// only — this shape is banned in real sidebar rows by
/// `scripts/check-sidebar-lazy-layout.py`.
private struct DivergentGeometryFeedbackRowFixture: View {
    let onBody: () -> Void
    @State private var rowHeight: CGFloat = 20

    var body: some View {
        let _ = { onBody() }()
        Color.gray
            .frame(height: rowHeight)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { rowHeight = proxy.size.height + 1 }
                        .onChange(of: proxy.size.height) { _, newHeight in
                            rowHeight = newHeight + 1
                        }
                }
            }
    }
}
