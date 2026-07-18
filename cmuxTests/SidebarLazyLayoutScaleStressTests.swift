import AppKit
import CmuxWorkspaces
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension SidebarLazyLayoutScaleTests {
    /// Removing the observing view must tear down both merged Combine producers
    /// and their actor-stream consumers; later workspace changes cannot escape
    /// the cancelled SwiftUI task tree.
    @Test
    @MainActor
    func testWorkspaceObservationProducersAndConsumersCancelWithView() async throws {
        _ = NSApplication.shared

        let workspace = Workspace(title: "Observed")
        let counter = RowBodyCounter()
        var observationLifetime: NSObject? = NSObject()
        weak var weakObservationLifetime = observationLifetime
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }
        window.contentView = NSHostingView(
            rootView: Color.clear.sidebarWorkspaceObservations(
                ids: [workspace.id],
                workspaces: [workspace],
                debouncedInterval: .zero
            ) { [observationLifetime] workspaceId in
                _ = observationLifetime
                if workspaceId == workspace.id {
                    counter.workspaceSnapshotBuilds += 1
                }
            }
        )
        observationLifetime = nil

        await Self.drainMainRunLoop(for: window, iterations: 20)
        #expect(counter.workspaceSnapshotBuilds > 0)

        window.contentView = nil
        await Self.drainMainRunLoop(for: window, iterations: 20)
        let deliveriesAfterCancellation = counter.workspaceSnapshotBuilds
        #expect(
            weakObservationLifetime == nil,
            "Removing the view must release its observation task without a later publisher event."
        )

        workspace.isPinned.toggle()
        await Self.drainMainRunLoop(for: window, iterations: 20)
        #expect(counter.workspaceSnapshotBuilds == deliveriesAfterCancellation)
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
        // Unified-log positions are coarse and ingestion can lag. Timestamp
        // the workload after mount settles, then recheck each entry date so
        // app-host startup warnings cannot be attributed to this churn phase.
        let logStart = Date()

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

        let faults = try Self.viewUpdateFaultMessages(since: logStart)
        #expect(faults.isEmpty, "Sidebar churn emitted runtime faults: \(faults)")
    }

    /// Harness self-test: prove the drain loop + body counter detect an
    /// autonomous invalidation chain without embedding the banned
    /// GeometryReader → @State feedback shape in test code.
    @Test
    @MainActor
    func testHarnessDetectsRepeatedBodyInvalidationCanary() async throws {
        _ = NSApplication.shared

        let counter = RowBodyCounter()
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
        window.contentView = NSHostingView(rootView: AutonomousBodyInvalidationFixture(
            onBody: { counter.workspaceRowBodies += 1 }
        ))
        await Self.drainMainRunLoop(for: window, iterations: 80)

        #expect(
            counter.workspaceRowBodies >= 24,
            """
            The bounded autonomous invalidation fixture produced only \
            \(counter.workspaceRowBodies) body evaluations; the scale-test counter or \
            drain loop can no longer observe a self-sustaining render chain. \
            Fix the harness before trusting its livelock bounds.
            """
        )
    }
}

/// Bounded test-only render chain that mutates state after each body pass.
private struct AutonomousBodyInvalidationFixture: View {
    let onBody: () -> Void
    @State private var revision = 0

    var body: some View {
        let _ = { onBody() }()
        Color.gray
            .frame(height: 20)
            .id(revision)
            .task(id: revision) {
                guard revision < 32 else { return }
                revision += 1
            }
    }
}
