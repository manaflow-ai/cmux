import AppKit
import Combine
import CmuxWorkspaces
import OSLog
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension SidebarLazyLayoutScaleTests {
    /// A noisy workspace must not starve another workspace's pending change.
    /// The stream never goes quiet for the coalescing interval, so a debounce
    /// implementation would emit nothing until the loop stops. Keyed bounded
    /// coalescing must instead keep delivering and retain the quiet id.
    @Test
    @MainActor
    func testMergedObservationBatchIsLosslessAndNonStarvingDuringSustainedChurn() {
        let source = PassthroughSubject<UUID, Never>()
        let noisyWorkspaceId = UUID()
        let quietWorkspaceId = UUID()
        let subscriber = SidebarObservationBatchDemandSubscriber()
        let scheduler = VirtualCoalesceScheduler()
        SidebarWorkspaceObservationBatch.mergedChanges(
            from: [source.eraseToAnyPublisher()],
            for: .milliseconds(20),
            scheduler: scheduler
        )
        .subscribe(subscriber)
        defer { subscriber.cancel() }

        // The first two values establish the operator's replay and leading
        // edges. The quiet id then enters the keyed accumulator while the
        // noisy id keeps the source continuously active.
        source.send(noisyWorkspaceId)
        source.send(noisyWorkspaceId)
        source.send(quietWorkspaceId)

        #expect(subscriber.receivedBatches.isEmpty)
        subscriber.request(.unlimited)
        #expect(
            subscriber.receivedBatches.contains {
                $0.contains(noisyWorkspaceId) && $0.contains(quietWorkspaceId)
            },
            "Backpressure discarded a workspace identity while wakeups were conflated."
        )

        let deliveriesBeforeChurn = subscriber.receivedBatches.count
        for _ in 0..<3 {
            source.send(noisyWorkspaceId)
            scheduler.advance(by: 0.02)
            scheduler.runScheduledActions()
        }

        #expect(
            subscriber.receivedBatches.contains { $0.contains(quietWorkspaceId) },
            "A quiet workspace identity was lost behind another workspace's sustained updates."
        )
        #expect(
            subscriber.receivedBatches.count >= deliveriesBeforeChurn + 3,
            """
            Sustained input produced only \(subscriber.receivedBatches.count - deliveriesBeforeChurn) \
            deliveries; batching must have a bounded cadence, not wait for silence.
            """
        )
    }

    /// Group anchors have exactly one rendered identity: the header. This is
    /// the invariant used by table scrolling and drop-indicator lookup, and it
    /// rules out duplicate workspace ids in both expanded and collapsed lists.
    @Test
    @MainActor
    func testGroupedRenderItemsKeepAnchorExclusiveAndWorkspaceIdsUnique() {
        let top = Workspace(title: "Top")
        let anchor = Workspace(title: "Anchor")
        let firstMember = Workspace(title: "First member")
        let secondMember = Workspace(title: "Second member")
        let bottom = Workspace(title: "Bottom")
        let groupId = UUID()
        anchor.groupId = groupId
        firstMember.groupId = groupId
        secondMember.groupId = groupId

        var group = WorkspaceGroup(
            id: groupId,
            name: "Grouped",
            isCollapsed: false,
            isPinned: false,
            anchorWorkspaceId: anchor.id,
            customColor: nil,
            iconSymbol: nil
        )
        let tabs = [top, anchor, firstMember, secondMember, bottom]

        let expanded = SidebarWorkspaceRenderItem.renderItems(
            tabs: tabs,
            groupsById: [groupId: group]
        )
        let expandedWorkspaceIds = expanded.compactMap { item -> UUID? in
            guard case .workspace(let workspaceId) = item else { return nil }
            return workspaceId
        }
        let expandedHeaderCount = expanded.filter { item in
            guard case .groupHeader(let renderedGroupId, let anchorWorkspaceId) = item else {
                return false
            }
            return renderedGroupId == groupId && anchorWorkspaceId == anchor.id
        }.count

        #expect(expandedHeaderCount == 1)
        #expect(expandedWorkspaceIds == [top.id, firstMember.id, secondMember.id, bottom.id])
        #expect(!expandedWorkspaceIds.contains(anchor.id))
        #expect(Set(expanded.map(\.rowWorkspaceId)).count == expanded.count)

        group.isCollapsed = true
        let collapsed = SidebarWorkspaceRenderItem.renderItems(
            tabs: tabs,
            groupsById: [groupId: group]
        )
        let collapsedWorkspaceIds = collapsed.compactMap { item -> UUID? in
            guard case .workspace(let workspaceId) = item else { return nil }
            return workspaceId
        }
        let collapsedHeaderCount = collapsed.filter { item in
            guard case .groupHeader(let renderedGroupId, let anchorWorkspaceId) = item else {
                return false
            }
            return renderedGroupId == groupId && anchorWorkspaceId == anchor.id
        }.count

        #expect(collapsedHeaderCount == 1)
        #expect(collapsedWorkspaceIds == [top.id, bottom.id])
        #expect(Set(collapsed.map(\.rowWorkspaceId)).count == collapsed.count)
    }

    /// Churn variable-height content, scroll the table, and drive synthetic
    /// table-owned hover, then assert the run emitted zero SwiftUI/AppKit
    /// runtime faults. The #8004 hover-bridge loop and the #6707 scroll
    /// livelock both announced themselves through these exact log signatures
    /// before pegging the main thread.
    @Test
    @MainActor
    func testTableChurnScrollAndHoverEmitNoRuntimeFaults() async throws {
        let harness = try await Self.mountSidebar(workspaceCount: Self.workspaceCount)
        defer { harness.tearDown() }

        await Self.drainMainRunLoop(for: harness.window)
        let rootView = try #require(harness.window.contentView)
        let table = try #require(Self.tableView(in: rootView))
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

    /// Harness self-test: prove the drain loop + body counter actually detect
    /// a layout feedback loop. This fixture reproduces the historical
    /// GeometryReader → @State row-height shape (#6556) in divergent form; if
    /// the harness cannot flag THIS, the tests above are vacuous.
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

private final class SidebarObservationBatchDemandSubscriber: Subscriber {
    typealias Input = Set<UUID>
    typealias Failure = Never

    private var subscription: Subscription?
    private(set) var receivedBatches: [Set<UUID>] = []

    func receive(subscription: Subscription) {
        self.subscription = subscription
    }

    func receive(_ input: Set<UUID>) -> Subscribers.Demand {
        receivedBatches.append(input)
        return .none
    }

    func receive(completion: Subscribers.Completion<Never>) {}

    func request(_ demand: Subscribers.Demand) {
        subscription?.request(demand)
    }

    func cancel() {
        subscription?.cancel()
        subscription = nil
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
