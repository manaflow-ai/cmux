import Testing
import AppKit
import CmuxSidebar
import CmuxUpdater
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral gate for the feature-flagged AppKit sidebar's virtualization
/// contract: resolver and keyed-update work must stay O(visible rows) no matter
/// how many workspaces are open, and updates must converge.
///
/// The contract has regressed five times through five different mechanisms —
/// per-row anchorPreference aggregation (#5323), per-row String ids (#5764),
/// animated row-height interpolation (#5845), a force-measuring custom Layout
/// (#6210), and GeometryReader → @State row-height feedback (#6556) — and each
/// shipped to stable before being detected, because nothing exercised the
/// sidebar at the 100+ workspace scale where O(N) per pass becomes a
/// main-thread livelock (issue #2586). These tests mount the real
/// `VerticalTabsSidebar` at that scale, discover its native controller, and
/// count resolver calls through `SidebarLazyContractProbe`. They also prove
/// that the enabled AppKit path never executes retained SwiftUI workspace/group
/// row bodies.
@Suite(.serialized)
final class SidebarLazyLayoutScaleTests {
    static let workspaceCount = 1_000
    /// Generous ceiling for native snapshot resolvers in one 640pt viewport.
    /// The table shows roughly 20 rows; a virtualization defeat resolves all
    /// 1,000 workspace/group rows.
    private static let nativeResolverCeiling = 150

    final class InjectableMouseLocationWindow: NSWindow {
        var injectedMouseLocation = NSPoint.zero

        override var mouseLocationOutsideOfEventStream: NSPoint {
            injectedMouseLocation
        }
    }

    // Plain class (not @MainActor) so the probe's nonisolated `() -> Void`
    // closures can mutate it; all callbacks run on the main thread. The row
    // body counters must remain zero for the enabled AppKit sidebar.
    final class RowBodyCounter {
        var workspaceRowBodies = 0
        var groupHeaderBodies = 0
        var workspaceSnapshotBuilds = 0
        var workspaceRowInputProjections = 0
        // Snapshot builds bracketed by workspaceRowBody/workspaceRowBodyEnd,
        // i.e. synchronous work inside a single TabItemView.body evaluation.
        // Builds outside the bracket (onAppear refresh, observation publishers)
        // are legitimate and not counted here.
        var insideWorkspaceRowBody = false
        var snapshotBuildsInCurrentRowBody = 0
        var maxSnapshotBuildsInOneRowBody = 0
        func reset() {
            workspaceRowBodies = 0
            groupHeaderBodies = 0
            workspaceSnapshotBuilds = 0
            workspaceRowInputProjections = 0
            insideWorkspaceRowBody = false
            snapshotBuildsInCurrentRowBody = 0
            maxSnapshotBuildsInOneRowBody = 0
        }
    }

    @MainActor
    struct Harness {
        let tabManager: TabManager
        let unread: SidebarUnreadModel
        let counter: RowBodyCounter
        let window: InjectableMouseLocationWindow
        let defaultsSuiteName: String

        func nativeSidebarController() -> SidebarAppKitViewController? {
            guard let contentView = window.contentView else { return nil }
            return Self.findSidebarController(in: contentView)
        }

        func sidebarController() throws -> SidebarAppKitViewController {
            return try #require(
                nativeSidebarController(),
                "The enabled AppKit sidebar mounted without its native table controller."
            )
        }

        func visibleNonAnchorWorkspace(
            in controller: SidebarAppKitViewController
        ) throws -> Workspace {
            let visibleRows = Self.visibleRows(in: controller.tableView)
            let anchorWorkspaceIds = Set(
                tabManager.workspaceGroups.map(\.anchorWorkspaceId)
            )
            let workspace = tabManager.tabs.first { workspace in
                guard !anchorWorkspaceIds.contains(workspace.id),
                      let groupId = workspace.groupId,
                      let workspaceRow = controller.rowIndex(
                        for: .workspace(workspace.id)
                      ),
                      let groupRow = controller.rowIndex(for: .group(groupId)) else {
                    return false
                }
                return visibleRows.contains(workspaceRow)
                    && visibleRows.contains(groupRow)
            }
            return try #require(
                workspace,
                "No visible non-anchor workspace and group header were found."
            )
        }

        func offscreenWorkspace(
            in controller: SidebarAppKitViewController
        ) throws -> Workspace {
            let visibleRows = Self.visibleRows(in: controller.tableView)
            let anchorWorkspaceIds = Set(
                tabManager.workspaceGroups.map(\.anchorWorkspaceId)
            )
            let workspace = tabManager.tabs.reversed().first { workspace in
                guard !anchorWorkspaceIds.contains(workspace.id),
                      let row = controller.rowIndex(for: .workspace(workspace.id)) else {
                    return false
                }
                return !visibleRows.contains(row)
            }
            return try #require(
                workspace,
                "No offscreen non-anchor workspace was found."
            )
        }

        func tearDown() {
            window.contentView = nil
            window.close()
            UserDefaults(suiteName: defaultsSuiteName)?
                .removePersistentDomain(forName: defaultsSuiteName)
        }

        private static func findSidebarController(
            in view: NSView
        ) -> SidebarAppKitViewController? {
            if let tableView = view as? SidebarAppKitTableView,
               let controller = tableView.delegate as? SidebarAppKitViewController {
                return controller
            }
            for subview in view.subviews {
                if let controller = findSidebarController(in: subview) {
                    return controller
                }
            }
            return nil
        }

        private static func visibleRows(in tableView: NSTableView) -> IndexSet {
            let range = tableView.rows(in: tableView.visibleRect)
            guard range.location != NSNotFound, range.length > 0 else { return [] }
            let upperBound = min(tableView.numberOfRows, range.location + range.length)
            guard range.location < upperBound else { return [] }
            return IndexSet(integersIn: range.location..<upperBound)
        }
    }

    @MainActor
    static func mountSidebar(
        workspaceCount: Int,
        appKitSidebarEnabled: Bool = true
    ) async throws -> Harness {
        _ = NSApplication.shared

        // Hermetic defaults: VerticalTabsSidebar picks between the workspace
        // list and extension/built-in sidebars via
        // @AppStorage(CmuxExtensionSidebarSelection.defaultsKey). A persisted
        // non-default provider on the host would mount the wrong sidebar and
        // the probes would never fire. Same pattern as
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
        // group-header rows — assembled by sidebarWorkspaceGroupRow(...) in
        // VerticalTabsSidebar+WorkspaceGroups.swift, a historical regression
        // site (#4385) — are exercised by the same realization bounds.
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
        let counter = RowBodyCounter()

        let root = VerticalTabsSidebar(
            updateViewModel: UpdateStateModel(),
            fileExplorerState: FileExplorerState(),
            windowId: UUID(),
            onSendFeedback: {},
            onToggleSidebar: {},
            onNewTab: {},
            observedWindow: nil,
            tabManager: tabManager,
            sidebarUnread: unread,
            cmuxConfigStore: CmuxConfigStore(),
            selection: .constant(.tabs),
            selectedTabIds: .constant([]),
            lastSidebarSelectionIndex: .constant(nil),
            sidebarRenderWorkerClient: .constant(nil),
            appKitSidebarEnabledOverride: appKitSidebarEnabled
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
                workspaceRowBody: {
                    counter.workspaceRowBodies += 1
                    counter.insideWorkspaceRowBody = true
                    counter.snapshotBuildsInCurrentRowBody = 0
                },
                workspaceRowBodyEnd: {
                    counter.insideWorkspaceRowBody = false
                },
                groupHeaderRowBody: { counter.groupHeaderBodies += 1 },
                workspaceSnapshotBuild: {
                    counter.workspaceSnapshotBuilds += 1
                    guard counter.insideWorkspaceRowBody else { return }
                    counter.snapshotBuildsInCurrentRowBody += 1
                    counter.maxSnapshotBuildsInOneRowBody = max(
                        counter.maxSnapshotBuildsInOneRowBody,
                        counter.snapshotBuildsInCurrentRowBody
                    )
                },
                workspaceRowInputProjection: {
                    counter.workspaceRowInputProjections += 1
                }
            )
        )
        .defaultAppStorage(defaults)

        let window = InjectableMouseLocationWindow(
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

    @Test
    @MainActor
    func testAppKitSidebarFeatureFlagDefaultsOff() throws {
        let suiteName = "cmux.feature.flags.appkit-sidebar.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let flags = CmuxFeatureFlags(
            defaults: defaults,
            remoteFlagValueProvider: { _ in nil }
        )

        #expect(!flags.isAppKitSidebarEnabled)
    }

    @Test
    @MainActor
    func testDisabledAppKitSidebarFlagKeepsLegacyDefaultSidebar() async throws {
        let harness = try await Self.mountSidebar(
            workspaceCount: 20,
            appKitSidebarEnabled: false
        )
        defer { harness.tearDown() }

        await Self.drainMainRunLoop(for: harness.window)

        #expect(harness.nativeSidebarController() == nil)
        #expect(harness.counter.workspaceRowBodies > 0)
    }


    /// Mounting the sidebar with 1,000 workspaces must resolve only the rows a
    /// single native viewport needs. Resolving all rows makes every subsequent
    /// update pay O(total workspaces) on the main actor.
    @Test
    @MainActor
    func testMountResolvesOnlyViewportRowsAt1000Workspaces() async throws {
        let harness = try await Self.mountSidebar(workspaceCount: Self.workspaceCount)
        defer { harness.tearDown() }

        await Self.drainMainRunLoop(for: harness.window)
        let controller = try harness.sidebarController()
        let counts = controller.resolverInvocationCounts
        let nativeSnapshotResolutions = counts.workspaceSnapshots + counts.groupSnapshots

        #expect(controller.tableView.numberOfRows == Self.workspaceCount)
        #expect(
            counts.workspaceSnapshots > 0,
            "Sidebar mounted but no native workspace snapshot resolver ran."
        )
        #expect(
            counts.groupSnapshots > 0,
            "Grouped rows were visible but no native group snapshot resolver ran."
        )
        #expect(
            nativeSnapshotResolutions < Self.nativeResolverCeiling,
            """
            \(nativeSnapshotResolutions) native row snapshots resolved for one viewport with \
            \(Self.workspaceCount) workspaces. The AppKit table must resolve only visible rows.
            """
        )
        #expect(
            harness.counter.workspaceRowInputProjections == counts.workspaceSnapshots
        )
        #expect(counts.workspaceActions == counts.workspaceSnapshots)
        #expect(counts.groupActions == counts.groupSnapshots)
    }

    /// The enabled AppKit provider must remain fully native below its representable.
    /// Executing a retained SwiftUI workspace or group row would reintroduce
    /// AttributeGraph invalidation into the hot list path.
    @Test
    @MainActor
    func testEnabledAppKitSidebarExecutesNoSwiftUIWorkspaceOrGroupRowBodies() async throws {
        let harness = try await Self.mountSidebar(workspaceCount: Self.workspaceCount)
        defer { harness.tearDown() }

        await Self.drainMainRunLoop(for: harness.window)

        _ = try harness.sidebarController()
        #expect(harness.counter.workspaceRowBodies == 0)
        #expect(harness.counter.groupHeaderBodies == 0)
        #expect(harness.counter.workspaceSnapshotBuilds == 0)
        #expect(harness.counter.maxSnapshotBuildsInOneRowBody == 0)
    }

    /// Offscreen workspaces have no native cell and no live row observation.
    /// Their publishers must not project or reload any row.
    @Test
    @MainActor
    func testOffscreenWorkspacePublisherChangeProjectsNoRows() async throws {
        let harness = try await Self.mountSidebar(workspaceCount: Self.workspaceCount)
        defer { harness.tearDown() }

        await Self.drainMainRunLoop(for: harness.window)
        let controller = try harness.sidebarController()
        let target = try harness.offscreenWorkspace(in: controller)
        let targetRow = try #require(controller.rowIndex(for: .workspace(target.id)))
        #expect(
            controller.tableView.rowView(
                atRow: targetRow,
                makeIfNecessary: false
            ) == nil
        )

        harness.counter.reset()
        controller.resetResolverInvocationCounts()
        target.statusEntries["issue-6707.offscreen"] = SidebarStatusEntry(
            key: "issue-6707.offscreen",
            value: "offscreen update",
            icon: "bolt.fill"
        )
        await Self.drainMainRunLoop(for: harness.window)

        #expect(harness.counter.workspaceRowInputProjections == 0)
        #expect(controller.resolverInvocationCounts.workspaceSnapshots == 0)
        #expect(controller.resolverInvocationCounts.groupSnapshots == 0)
        #expect(controller.resolverInvocationCounts.workspaceActions == 0)
        #expect(controller.resolverInvocationCounts.groupActions == 0)
        #expect(harness.counter.workspaceRowBodies == 0)
        #expect(harness.counter.groupHeaderBodies == 0)
    }

    /// A burst of unread-model updates must stay keyed to one visible
    /// non-anchor workspace and its group header. The native table must stop
    /// resolving rows when the burst stops.
    @Test
    @MainActor
    func testUnreadStormStaysRowScopedAndConverges() async throws {
        let harness = try await Self.mountSidebar(workspaceCount: Self.workspaceCount)
        defer { harness.tearDown() }

        await Self.drainMainRunLoop(for: harness.window)
        let controller = try harness.sidebarController()
        let target = try harness.visibleNonAnchorWorkspace(in: controller)
        harness.counter.reset()
        controller.resetResolverInvocationCounts()

        let storms = 40
        for i in 1...storms {
            harness.unread.apply(
                totalUnreadCount: i,
                summaries: [
                    target.id: SidebarWorkspaceUnreadSummary(
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

        let counts = controller.resolverInvocationCounts
        let workspaceProjections = harness.counter.workspaceRowInputProjections
        #expect(workspaceProjections > 0)
        #expect(
            workspaceProjections <= storms * 2,
            """
            \(workspaceProjections) workspace snapshots resolved for \(storms) unread updates. \
            Native updates must stay keyed to the changed visible workspace.
            """
        )
        #expect(counts.workspaceSnapshots == workspaceProjections)
        #expect(counts.groupSnapshots > 0)
        #expect(counts.groupSnapshots <= storms * 2)
        #expect(counts.workspaceActions == counts.workspaceSnapshots)
        #expect(counts.groupActions == counts.groupSnapshots)
        #expect(harness.counter.workspaceRowBodies == 0)
        #expect(harness.counter.groupHeaderBodies == 0)

        // Drain pending delivery first, then observe a fresh quiet interval.
        await Self.drainMainRunLoop(for: harness.window, iterations: 30)
        harness.counter.reset()
        controller.resetResolverInvocationCounts()
        await Self.drainMainRunLoop(for: harness.window, iterations: 30)
        #expect(harness.counter.workspaceRowInputProjections == 0)
        #expect(controller.resolverInvocationCounts.workspaceSnapshots == 0)
        #expect(controller.resolverInvocationCounts.groupSnapshots == 0)
        #expect(controller.resolverInvocationCounts.workspaceActions == 0)
        #expect(controller.resolverInvocationCounts.groupActions == 0)
        #expect(harness.counter.workspaceRowBodies == 0)
        #expect(harness.counter.groupHeaderBodies == 0)
    }

    /// Regression test for one unread change. A visible non-anchor workspace
    /// must resolve only its native workspace row and group header, independent
    /// of the total workspace count.
    @Test
    @MainActor
    func testSingleUnreadChangeProjectsOnlyTheChangedWorkspace() async throws {
        let harness = try await Self.mountSidebar(workspaceCount: Self.workspaceCount)
        defer { harness.tearDown() }

        await Self.drainMainRunLoop(for: harness.window)
        let controller = try harness.sidebarController()
        let target = try harness.visibleNonAnchorWorkspace(in: controller)
        harness.counter.reset()
        controller.resetResolverInvocationCounts()

        harness.unread.apply(
            totalUnreadCount: 1,
            summaries: [
                target.id: SidebarWorkspaceUnreadSummary(
                    unreadCount: 1,
                    latestNotificationText: "one changed workspace"
                )
            ],
            unreadSurfaceKeys: [],
            focusedReadIndicatorByWorkspaceId: [:],
            manualUnreadWorkspaceIds: []
        )

        let refreshDeadline = ProcessInfo.processInfo.systemUptime + 3
        while harness.counter.workspaceRowInputProjections == 0,
              ProcessInfo.processInfo.systemUptime < refreshDeadline {
            Self.turnMainRunLoopOnce(layingOut: harness.window)
            await Task.yield()
        }
        await Self.drainMainRunLoop(for: harness.window)

        let projections = harness.counter.workspaceRowInputProjections
        let counts = controller.resolverInvocationCounts
        #expect(projections > 0, "The unread change never reached the sidebar projection owner.")
        #expect(
            projections <= 2,
            """
            One visible non-anchor unread change resolved \(projections) workspace snapshots at \
            a scale of \(Self.workspaceCount). The update must remain keyed to that workspace.
            """
        )
        #expect(counts.workspaceSnapshots == projections)
        #expect(counts.groupSnapshots > 0)
        #expect(counts.groupSnapshots <= 2)
        #expect(counts.workspaceActions == counts.workspaceSnapshots)
        #expect(counts.groupActions == counts.groupSnapshots)
        #expect(harness.counter.workspaceRowBodies == 0)
        #expect(harness.counter.groupHeaderBodies == 0)
    }


    /// Harness self-test: prove the drain loop + body counter actually detect
    /// a layout feedback loop. This fixture reproduces the historical
    /// GeometryReader → @State row-height shape (#6556) in divergent form; if
    /// the harness cannot flag THIS, the two tests above are vacuous.
    @Test
    @MainActor
    func testHarnessDetectsGeometryFeedbackLoopCanary() async throws {
        _ = NSApplication.shared

        let counter = RowBodyCounter()
        let rows = 8
        let root = VStack(spacing: 2) {
            ForEach(0..<rows, id: \.self) { _ in
                DivergentGeometryFeedbackRowFixture(onBody: { counter.workspaceRowBodies += 1 })
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
            counter.workspaceRowBodies > rows * 3,
            """
            The divergent GeometryReader → @State fixture only produced \
            \(counter.workspaceRowBodies) body evaluations for \(rows) rows; the harness \
            can no longer observe layout feedback loops, so the lazy-contract tests above \
            are not protecting anything. Fix the harness before trusting them.
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
