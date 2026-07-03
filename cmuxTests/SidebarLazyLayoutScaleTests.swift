import Testing
import AppKit
import CmuxUpdater
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral gate for the workspace sidebar's lazy-layout contract: layout
/// and diff work must stay O(visible rows) no matter how many workspaces are
/// open, and updates must converge (no self-sustaining invalidation).
///
/// The contract has regressed five times through five different mechanisms —
/// per-row anchorPreference aggregation (#5323), per-row String ids (#5764),
/// animated row-height interpolation (#5845), a force-measuring custom Layout
/// (#6210), and GeometryReader → @State row-height feedback (#6556) — and each
/// shipped to stable before being detected, because nothing exercised the
/// sidebar at the 100+ workspace scale where O(N) per pass becomes a
/// main-thread livelock (issue #2586). These tests mount the real
/// `VerticalTabsSidebar` at that scale and count actual row body evaluations
/// through `SidebarLazyContractProbe`, so ANY future mechanism that realizes
/// the whole list or loops the AttributeGraph fails here instead of on a
/// user's machine. `scripts/check-sidebar-lazy-layout.py` bans the known
/// source shapes; this is the mechanism-independent backstop.
@Suite(.serialized)
final class SidebarLazyLayoutScaleTests {
    private static let workspaceCount = 300
    /// Generous ceiling for "how many rows may be realized for one viewport".
    /// A 640pt window shows ~20 rows; LazyVStack prefetch and a second layout
    /// pass can multiply that, but a virtualization defeat realizes all 300.
    private static let realizedRowCeiling = 150

    // Plain class (not @MainActor) so the probe's nonisolated `() -> Void`
    // closures can mutate it; bodies only run on the main thread. Same shape
    // as MinimalModeBodyProbeCounts in WorkspaceContentViewVisibilityTests.
    private final class RowBodyCounter {
        var workspaceRowBodies = 0
        var groupHeaderBodies = 0
        func reset() {
            workspaceRowBodies = 0
            groupHeaderBodies = 0
        }
    }

    @MainActor
    private struct Harness {
        let tabManager: TabManager
        let unread: SidebarUnreadModel
        let counter: RowBodyCounter
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
    private static func mountSidebar(workspaceCount: Int) async throws -> Harness {
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
        // group-header rows — assembled by sidebarWorkspaceGroupHeader(...) in
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
                workspaceRowBody: { counter.workspaceRowBodies += 1 },
                groupHeaderRowBody: { counter.groupHeaderBodies += 1 }
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
    private static func turnMainRunLoopOnce(layingOut window: NSWindow?) {
        autoreleasepool {
            window?.contentView?.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }
    }

    @MainActor
    private static func drainMainRunLoop(for window: NSWindow, iterations: Int = 25) async {
        for _ in 0..<iterations {
            Self.turnMainRunLoopOnce(layingOut: window)
            await Task.yield()
        }
    }

    /// Mounting the sidebar with 300 workspaces must realize only the rows a
    /// single viewport needs. Realizing all of them is the #5323/#6210 defeat:
    /// at scale, every subsequent update pays an O(N) layout pass and the main
    /// thread livelocks.
    @Test
    @MainActor
    func testMountRealizesOnlyViewportRowsAt300Workspaces() async throws {
        let harness = try await Self.mountSidebar(workspaceCount: Self.workspaceCount)
        defer { harness.tearDown() }

        await Self.drainMainRunLoop(for: harness.window)

        let realized = harness.counter.workspaceRowBodies
        #expect(realized > 0, "Sidebar mounted but no workspace row body ran; harness is broken.")
        #expect(
            realized < Self.realizedRowCeiling,
            """
            \(realized) workspace row bodies evaluated for a single ~20-row viewport with \
            \(Self.workspaceCount) workspaces. The LazyVStack is being defeated (all rows \
            realized per pass) — the #2586 sidebar livelock class. Look for per-row geometry \
            feedback (GeometryReader/@State height, anchorPreference aggregation) or a \
            force-measuring Layout; see scripts/check-sidebar-lazy-layout.py.
            """
        )

        let headerRealized = harness.counter.groupHeaderBodies
        #expect(
            headerRealized > 0,
            """
            Groups were created at the top of the list but no group-header body ran; the \
            grouped-workspace coverage is broken.
            """
        )
        #expect(
            headerRealized < Self.realizedRowCeiling,
            """
            \(headerRealized) group-header bodies evaluated for 5 groups in one viewport. \
            The group-header row wrapper (sidebarWorkspaceGroupHeader) is defeating \
            virtualization or re-evaluating without bound — the #4385 regression site.
            """
        )
    }

    /// A burst of unread-model updates (the agent-notification churn path,
    /// the sidebar's highest-frequency whole-body invalidation) must cost
    /// O(changed rows), and the sidebar must go quiet when the burst stops.
    /// Unbounded or non-converging row re-evaluation here is the exact
    /// signature of the #6556 GeometryReader → @State feedback livelock.
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

        let stormEvals = harness.counter.workspaceRowBodies
        #expect(
            stormEvals < storms * 10,
            """
            \(stormEvals) workspace row bodies evaluated for \(storms) single-workspace unread \
            updates. Updates must invalidate only the changed rows (TabItemView.== + \
            .equatable()), not re-evaluate the list. \(Self.workspaceCount) workspaces × \
            \(storms) updates re-realizing per pass is the #2586 livelock at scale.
            """
        )

        harness.counter.reset()
        await Self.drainMainRunLoop(for: harness.window, iterations: 30)
        let quietEvals = harness.counter.workspaceRowBodies + harness.counter.groupHeaderBodies
        #expect(
            quietEvals < 20,
            """
            \(quietEvals) row bodies (workspace + group header) evaluated with no state \
            changes at all. The sidebar is re-invalidating itself — a layout/state feedback \
            loop (the #6556 signature). This livelocks the main thread at scale.
            """
        )
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
