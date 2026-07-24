import AppKit
import CmuxSidebar
import CoreGraphics
import OSLog
import SwiftUI
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension SidebarLazyLayoutScaleTests {
    @MainActor
    fileprivate static func firstScrollView(in rootView: NSView) -> NSScrollView? {
        var pendingViews = [rootView]
        while let view = pendingViews.popLast() {
            if let scrollView = view as? NSScrollView { return scrollView }
            pendingViews.append(contentsOf: view.subviews)
        }
        return nil
    }

    private static func mouseMovedEvent(at pointInWindow: NSPoint, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))
    }

    fileprivate static func viewUpdateFaultMessages(since startDate: Date) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: startDate))
        let faultFragments = [
            "Modifying state during view update",
            "Publishing changes from within view updates",
            "laid out reentrantly",
        ]
        return entries.compactMap { entry in
            // OSLogStore positions are coarse and may begin before the exact
            // requested Date. Recheck the entry timestamp so one-time app-host
            // mount warnings cannot be attributed to the later stress phase.
            guard entry.date >= startDate,
                  let message = (entry as? OSLogEntryLog)?.composedMessage,
                  faultFragments.contains(where: message.localizedCaseInsensitiveContains) else {
                return nil
            }
            return message
        }
    }

    /// A stationary pointer over a row must survive the highest-risk sidebar
    /// churn without producing SwiftUI view-update or NSHostingView reentrant
    /// layout faults. The injectable window makes the production pointer owner
    /// see a real in-row pointer without requiring a key window or physical
    /// mouse, while scroll, remount, unread, and appearance changes exercise
    /// the #8004 lifecycle path.
    @Test
    @MainActor
    func testStationaryPointerChurnHasNoViewUpdateFaultsAndConverges() async throws {
        let logStart = Date()
        let harness = try await Self.mountSidebar(workspaceCount: Self.workspaceCount)
        defer { harness.tearDown() }

        await Self.drainMainRunLoop(for: harness.window)
        #expect(
            harness.window.acceptsMouseMovedEvents,
            "A mounted sidebar must enable mouse movement without discovering SwiftUI's private scroll-view hierarchy."
        )
        let rootView = try #require(harness.window.contentView)
        let scrollView = try #require(Self.firstScrollView(in: rootView))
        let pointerInScrollView = NSPoint(
            x: scrollView.bounds.midX,
            y: scrollView.bounds.maxY - 80
        )
        let pointerInWindow = scrollView.convert(pointerInScrollView, to: nil)
        harness.window.injectedMouseLocation = pointerInWindow

        harness.counter.reset()
        NSApp.sendEvent(try Self.mouseMovedEvent(
            at: pointerInWindow,
            window: harness.window
        ))
        await Self.drainMainRunLoop(for: harness.window, iterations: 4)
        let hoverFlipEvals = harness.counter.workspaceRowBodies + harness.counter.groupHeaderBodies
        #expect(
            (1...2).contains(hoverFlipEvals),
            """
            One hover-owner change evaluated \(hoverFlipEvals) row bodies. The parent may \
            recompute row values, but Equatable rows must limit body work to the old/new hover \
            targets (at most two rows).
            """
        )

        harness.counter.reset()
        let stormTargets = Array(harness.tabManager.tabs.prefix(3).map(\.id))
        let groupIds = harness.tabManager.workspaceGroups.map(\.id)
        for i in 1...40 {
            let target = stormTargets[i % stormTargets.count]
            harness.unread.apply(
                totalUnreadCount: i,
                summaries: [
                    target: SidebarWorkspaceUnreadSummary(
                        unreadCount: i,
                        latestNotificationText: "stationary pointer churn \(i)"
                    )
                ],
                unreadSurfaceKeys: [],
                focusedReadIndicatorByWorkspaceId: [:],
                manualUnreadWorkspaceIds: []
            )

            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let maximumOffset = max(0, documentHeight - scrollView.contentView.bounds.height)
            let requestedOffset = CGFloat((i % 8) * 36)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(maximumOffset, requestedOffset)))
            scrollView.reflectScrolledClipView(scrollView.contentView)

            if i.isMultiple(of: 4), let groupId = groupIds.first {
                harness.tabManager.toggleWorkspaceGroupCollapsed(groupId: groupId)
            }
            harness.window.appearance = NSAppearance(
                named: i.isMultiple(of: 2) ? .darkAqua : .aqua
            )
            await Self.drainMainRunLoop(for: harness.window, iterations: 2)
        }
        await Self.drainMainRunLoop(for: harness.window)

        let faultMessages = try Self.viewUpdateFaultMessages(since: logStart)
        #expect(
            faultMessages.isEmpty,
            """
            Sidebar stationary-pointer churn emitted \(faultMessages.count) SwiftUI/AppKit \
            view-update faults:\n\(faultMessages.joined(separator: "\n"))
            """
        )

        harness.counter.reset()
        await Self.drainMainRunLoop(for: harness.window, iterations: 30)
        let quietEvals = harness.counter.workspaceRowBodies + harness.counter.groupHeaderBodies
        #expect(
            quietEvals < 20,
            """
            \(quietEvals) row bodies evaluated after stationary-pointer churn ended. The sidebar failed to converge \
            and is still feeding interaction or geometry changes back into layout.
            """
        )
    }

}

/// Reporter-shaped regression suite for #6707, amplified beyond LazyVStack's
/// prefetch range so every scroll cycle must realize and retire rows. It is
/// separate from the broader scale suite so CI can run this workload alone; a
/// method-level `-only-testing` selector does not select Swift Testing cases.
@Suite(.serialized)
final class SidebarOverflowingScrollStatusChurnTests {
    private static func scrollWheelEvent(
        deltaY: Int32,
        phase: Int64,
        at pointInWindow: NSPoint,
        window: NSWindow
    ) throws -> NSEvent {
        let event = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: deltaY,
            wheel2: 0,
            wheel3: 0
        ))
        event.location = window.convertPoint(toScreen: pointInWindow)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        return try #require(NSEvent(cgEvent: event))
    }

    @Test
    @MainActor
    func testOverflowingScrollWithStatusChurnHasNoLayoutReentryAndConverges() async throws {
        let harness = try await SidebarLazyLayoutScaleTests.mountSidebar(workspaceCount: 120)
        defer { harness.tearDown() }

        await SidebarLazyLayoutScaleTests.drainMainRunLoop(for: harness.window)
        let rootView = try #require(harness.window.contentView)
        let scrollView = try #require(SidebarLazyLayoutScaleTests.firstScrollView(in: rootView))
        let eventPoint = scrollView.convert(
            NSPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY),
            to: nil
        )
        let statusTargets = Array(harness.tabManager.tabs.suffix(8))
        #expect(!statusTargets.isEmpty)
        // App-host startup mounts the full application around the test view
        // and can emit unrelated one-time hosting warnings. The reporter
        // workload begins only after this sidebar has mounted and converged.
        let logStart = Date()

        harness.counter.reset()
        for iteration in 0..<32 {
            let target = statusTargets[iteration % statusTargets.count]
            let key = "issue-6707.status"
            let snapshotBuildsBeforeMutation = harness.counter.workspaceSnapshotBuilds
            if (iteration / statusTargets.count).isMultiple(of: 2) {
                target.statusEntries[key] = SidebarStatusEntry(
                    key: key,
                    value: "CLI status update \(iteration)",
                    icon: "bolt.fill"
                )
            } else {
                target.statusEntries.removeValue(forKey: key)
            }

            // Re-read the live document height because adding/removing a
            // status row changes it. The sawtooth repeatedly crosses both lazy
            // realization boundaries instead of only adjusting one offset.
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let maximumOffset = max(0, documentHeight - scrollView.contentView.bounds.height)
            let phase = CGFloat(iteration % 8) / 7
            let requestedOffset = iteration.isMultiple(of: 2)
                ? maximumOffset * phase
                : maximumOffset * (1 - phase)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: requestedOffset))
            scrollView.reflectScrolledClipView(scrollView.contentView)

            // Absolute offsets make the test deterministic; a continuous
            // wheel event then drives AppKit's live-scroll transaction around
            // that lazy-realization boundary, matching the reporter gesture.
            let scrollPhase: Int64
            switch iteration % 8 {
            case 0: scrollPhase = 1 // kCGScrollPhaseBegan
            case 7: scrollPhase = 4 // kCGScrollPhaseEnded
            default: scrollPhase = 2 // kCGScrollPhaseChanged
            }
            scrollView.scrollWheel(with: try Self.scrollWheelEvent(
                deltaY: iteration.isMultiple(of: 2) ? -48 : 48,
                phase: scrollPhase,
                at: eventPoint,
                window: harness.window
            ))

            // Wait on the keyed per-workspace refresh itself, not a scheduler
            // delay. This proves every mutation reached the parent snapshot
            // boundary while the live-scroll transaction was active.
            let refreshDeadline = ProcessInfo.processInfo.systemUptime + 2
            while harness.counter.workspaceSnapshotBuilds <= snapshotBuildsBeforeMutation,
                  ProcessInfo.processInfo.systemUptime < refreshDeadline {
                SidebarLazyLayoutScaleTests.turnMainRunLoopOnce(layingOut: harness.window)
                await Task.yield()
            }
            #expect(
                harness.counter.workspaceSnapshotBuilds > snapshotBuildsBeforeMutation,
                "Workspace \(target.id) did not publish a keyed sidebar snapshot refresh for iteration \(iteration)."
            )
        }
        await SidebarLazyLayoutScaleTests.drainMainRunLoop(for: harness.window)

        let faultMessages = try SidebarLazyLayoutScaleTests.viewUpdateFaultMessages(since: logStart)
        #expect(
            faultMessages.isEmpty,
            """
            Overflowing sidebar scroll + status churn emitted \(faultMessages.count) SwiftUI/AppKit \
            view-update faults:\n\(faultMessages.joined(separator: "\n"))
            """
        )

        harness.counter.reset()
        await SidebarLazyLayoutScaleTests.drainMainRunLoop(for: harness.window, iterations: 40)
        let quietEvals = harness.counter.workspaceRowBodies + harness.counter.groupHeaderBodies
        #expect(
            quietEvals < 20,
            """
            \(quietEvals) row bodies evaluated after scrolling and status churn ended. The sidebar \
            did not converge and is still feeding lazy layout back into view state.
            """
        )
    }
}

/// Guards the two ownership boundaries that keep AppKit-hosted SwiftUI layout
/// from publishing state while `LazyVStack` is placing `ForEach` children.
/// These are deterministic causal checks, not another attempt to win the
/// timing race that made the reporter-shaped #6707 stress test pass pre-fix.
@Suite(.serialized)
final class SidebarHierarchyOwnershipTests {
    private struct ObservationTopology: Equatable {
        let agentObserverIDsByWorkspace: [UUID: Set<UUID>]
        let processTitleObserverIDsByWorkspace: [UUID: Set<UUID>]
    }

    @MainActor
    private static func observationTopology(
        for harness: SidebarLazyLayoutScaleTests.Harness
    ) -> ObservationTopology {
        ObservationTopology(
            agentObserverIDsByWorkspace: Dictionary(
                uniqueKeysWithValues: harness.tabManager.tabs.map {
                    ($0.id, Set($0.sidebarAgentRuntimeObservation.changeObservers.keys))
                }
            ),
            processTitleObserverIDsByWorkspace: Dictionary(
                uniqueKeysWithValues: harness.tabManager.tabs.map {
                    ($0.id, Set($0.sidebarProcessTitleObservation.changeObservers.keys))
                }
            )
        )
    }

    @MainActor
    private static func waitForInitialParentObservations(
        in harness: SidebarLazyLayoutScaleTests.Harness
    ) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            let topology = observationTopology(for: harness)
            let agentReady = topology.agentObserverIDsByWorkspace.values.allSatisfy { $0.count == 1 }
            let processTitleReady = topology.processTitleObserverIDsByWorkspace.values.allSatisfy { $0.count == 1 }
            if agentReady, processTitleReady {
                break
            }
            SidebarLazyLayoutScaleTests.turnMainRunLoopOnce(layingOut: harness.window)
            await Task.yield()
        }

        let settledTopology = observationTopology(for: harness)
        #expect(
            settledTopology.agentObserverIDsByWorkspace.values.allSatisfy { $0.count == 1 },
            "Every workspace must settle with one parent-owned agent observer."
        )
        #expect(
            settledTopology.processTitleObserverIDsByWorkspace.values.allSatisfy { $0.count == 1 },
            "Every workspace must settle with one parent-owned process-title observer."
        )
    }

    /// Viewport size is a downward-only input to the hosted scroll hierarchy.
    /// The pre-fix `.onGeometryChange` wrote it into owner `@State`, causing a
    /// second `VerticalTabsSidebar.body` pass from inside the same graph that
    /// was laying out `LazyVStack`. Direct GeometryReader input must not do so.
    @Test
    @MainActor
    func testViewportResizeDoesNotPublishBackIntoSidebarOwner() async throws {
        let harness = try await SidebarLazyLayoutScaleTests.mountSidebar(workspaceCount: 120)
        defer { harness.tearDown() }

        await Self.waitForInitialParentObservations(in: harness)
        harness.counter.reset()

        for height in [560, 680, 520, 640, 580, 700, 540, 660] {
            harness.counter.isViewportResizeActive = true
            harness.window.setContentSize(NSSize(width: 280, height: height))
            SidebarLazyLayoutScaleTests.turnMainRunLoopOnce(layingOut: harness.window)
            await Task.yield()
            SidebarLazyLayoutScaleTests.turnMainRunLoopOnce(layingOut: harness.window)
            harness.counter.isViewportResizeActive = false
        }
        await SidebarLazyLayoutScaleTests.drainMainRunLoop(
            for: harness.window,
            iterations: 20
        )

        #expect(
            harness.counter.verticalSidebarBodiesDuringViewportResize == 0,
            """
            Viewport-only resizing re-evaluated VerticalTabsSidebar.body \
            \(harness.counter.verticalSidebarBodiesDuringViewportResize) times inside the \
            resize transaction. Geometry must flow directly \
            down into scroll content; publishing it through owner state re-enters the \
            NSHostingView → LazyVStack placement graph.
            """
        )
    }

    /// Crossing lazy-realization boundaries must be presentation-only. Before
    /// #8211, each newly mounted TabItemView started model observers and called
    /// `refreshWorkspaceSnapshot(force: true)`, publishing row `@State` while
    /// SwiftUI was placing that row. Parent-owned observers and immutable
    /// snapshots must remain unchanged throughout pure scrolling.
    @Test
    @MainActor
    func testPureScrollDoesNotPublishFromLazyRowLifecycle() async throws {
        let harness = try await SidebarLazyLayoutScaleTests.mountSidebar(
            workspaceCount: SidebarLazyLayoutScaleTests.workspaceCount
        )
        defer { harness.tearDown() }

        await Self.waitForInitialParentObservations(in: harness)
        let topologyBeforeScroll = Self.observationTopology(for: harness)
        let initiallyRealizedWorkspaceIds = harness.counter.realizedWorkspaceIds
        #expect(
            topologyBeforeScroll.agentObserverIDsByWorkspace.values.allSatisfy { $0.count == 1 },
            "Every workspace must have one parent-owned agent observer before scrolling."
        )
        #expect(
            topologyBeforeScroll.processTitleObserverIDsByWorkspace.values.allSatisfy { $0.count == 1 },
            "Every workspace must have one parent-owned process-title observer before scrolling."
        )

        let rootView = try #require(harness.window.contentView)
        let scrollView = try #require(SidebarLazyLayoutScaleTests.firstScrollView(in: rootView))
        let documentHeight = try #require(scrollView.documentView?.bounds.height)
        let viewportHeight = scrollView.contentView.bounds.height
        let maximumOffset = max(0, documentHeight - viewportHeight)
        try #require(
            maximumOffset > viewportHeight,
            "The production sidebar fixture must overflow by more than one viewport."
        )

        harness.counter.reset()
        for offset in [maximumOffset, 0, maximumOffset / 2, maximumOffset, 0] {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            await SidebarLazyLayoutScaleTests.drainMainRunLoop(
                for: harness.window,
                iterations: 6
            )
            #expect(
                Self.observationTopology(for: harness) == topologyBeforeScroll,
                """
                Pure scrolling changed workspace observer identities. Model observation must \
                be owned above the lazy renderer, independent of row appearance and disappearance.
                """
            )
        }

        let newlyRealizedWorkspaceIds = harness.counter.realizedWorkspaceIds
            .subtracting(initiallyRealizedWorkspaceIds)
        #expect(
            !newlyRealizedWorkspaceIds.isEmpty,
            """
            Scrolling did not realize any workspace outside the initial viewport; the \
            lazy-row lifecycle assertion is vacuous.
            """
        )
    }
}

/// Renderer-neutral scale fixture for the production immutable row boundary.
/// It reaches the same NSHostingView/LazyVStack/ForEach/TabItemView chain as
/// the live sidebar without constructing 1,000 Workspace terminal graphs.
/// An AppKit renderer can reuse these exact row values and operation bounds.
@Suite(.serialized)
final class SidebarImmutableRowScaleTests {
    private static let realizedRowCeiling = 150

    @MainActor
    private struct Harness {
        let window: NSWindow
        let counter: SidebarLazyLayoutScaleTests.RowBodyCounter
        let defaults: UserDefaults
        let defaultsSuiteName: String

        func tearDown() {
            window.contentView = nil
            window.close()
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
    }

    @Test
    @MainActor
    func testProductionRowsStayViewportBoundedFromOneToOneThousand() async throws {
        for workspaceCount in [1, 10, 100, 1_000] {
            let harness = try Self.mountRows(workspaceCount: workspaceCount)
            defer { harness.tearDown() }

            await SidebarLazyLayoutScaleTests.drainMainRunLoop(for: harness.window)
            let initialRowBodies = harness.counter.workspaceRowBodies
            #expect(
                initialRowBodies > 0,
                "The production row hierarchy did not render at scale \(workspaceCount)."
            )
            #expect(
                initialRowBodies < Self.realizedRowCeiling,
                """
                Initial layout evaluated \(initialRowBodies) row bodies for \
                \(workspaceCount) immutable rows. Work must remain bounded by the \
                viewport, not grow with the total row count.
                """
            )

            let rootView = try #require(harness.window.contentView)
            let scrollView = try #require(SidebarLazyLayoutScaleTests.firstScrollView(in: rootView))
            let documentHeight = try #require(scrollView.documentView?.bounds.height)
            let maximumOffset = max(0, documentHeight - scrollView.contentView.bounds.height)
            var maximumJumpRowBodies = 0
            if maximumOffset > 0 {
                for offset in [maximumOffset, 0, maximumOffset / 2, maximumOffset, 0] {
                    harness.counter.reset()
                    scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                    await SidebarLazyLayoutScaleTests.drainMainRunLoop(
                        for: harness.window,
                        iterations: 6
                    )
                    maximumJumpRowBodies = max(
                        maximumJumpRowBodies,
                        harness.counter.workspaceRowBodies
                    )
                    #expect(
                        harness.counter.workspaceRowBodies < Self.realizedRowCeiling,
                        """
                        One scroll jump evaluated \(harness.counter.workspaceRowBodies) \
                        row bodies at scale \(workspaceCount). Lazy realization must remain \
                        viewport-bounded at every position.
                        """
                    )
                    #expect(
                        harness.counter.workspaceSnapshotBuilds == 0,
                        "Immutable row realization must never rebuild workspace snapshots."
                    )
                }
            }

            harness.counter.reset()
            await SidebarLazyLayoutScaleTests.drainMainRunLoop(
                for: harness.window,
                iterations: 30
            )
            let quietRowBodies = harness.counter.workspaceRowBodies
            #expect(
                quietRowBodies < 20,
                """
                The immutable row hierarchy evaluated \(quietRowBodies) bodies after \
                inputs stopped at scale \(workspaceCount); layout did not converge.
                """
            )
            print(
                "SIDEBAR_SCALE_BASELINE " +
                "{\"workspaceCount\":\(workspaceCount)," +
                "\"initialRowBodies\":\(initialRowBodies)," +
                "\"maximumJumpRowBodies\":\(maximumJumpRowBodies)," +
                "\"quietRowBodies\":\(quietRowBodies)}"
            )
        }
    }

    @MainActor
    private static func mountRows(workspaceCount: Int) throws -> Harness {
        _ = NSApplication.shared
        let defaultsSuiteName = "SidebarImmutableRowScaleTests.\(workspaceCount).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let workspace = SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot(
            title: "Scale workspace"
        )
        let contextMenu = SidebarWorkspaceContextMenuSnapshot(
            targetWorkspaceIds: [],
            remoteTargetWorkspaceIds: [],
            allRemoteTargetsConnecting: false,
            allRemoteTargetsDisconnected: false,
            pinState: nil,
            groupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
            canCreateEmptyGroup: true,
            eligibleGroupTargetIds: [],
            allEligibleTargetsGroupId: nil,
            hasGroupedEligibleTarget: false,
            todoStatusLanes: [],
            canMarkRead: false,
            canMarkUnread: false,
            hasLatestNotification: false,
            notifications: []
        )
        let snapshots = (0..<workspaceCount).map { index in
            SidebarWorkspaceRowSnapshot(
                workspaceId: deterministicWorkspaceID(index: index),
                groupId: nil,
                index: index,
                workspaceCount: workspaceCount,
                workspace: workspace,
                isActive: index == 0,
                isMultiSelected: false,
                hasUserCustomTitle: false,
                hasCustomTitle: false,
                hasCustomDescription: false,
                customTitle: nil,
                workspaceShortcutDigit: index < 9 ? index + 1 : nil,
                workspaceShortcutModifierSymbol: "⌘",
                canCloseWorkspace: workspaceCount > 1,
                unreadCount: 0,
                latestNotificationText: nil,
                showsAgentActivity: false,
                rowSpacing: 0,
                showsModifierShortcutHints: false,
                isPointerHovering: false,
                isBeingDragged: false,
                topDropIndicatorVisible: false,
                bottomDropIndicatorVisible: false,
                isBonsplitWorkspaceDropActive: false,
                settings: settings,
                isChecklistExpanded: false,
                checklistAddFieldActivationToken: 0,
                isChecklistPopoverPresented: false,
                contextMenu: contextMenu
            )
        }
        #expect(Set(snapshots.map(\.workspaceId)).count == workspaceCount)

        let counter = SidebarLazyLayoutScaleTests.RowBodyCounter()
        let actions = Self.noOpActions()
        let root = ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(snapshots, id: \.workspaceId) { snapshot in
                    SidebarWorkspaceRowView(
                        snapshot: snapshot,
                        actions: actions,
                        shouldCollectWorkspaceDropTargets: false
                    )
                }
            }
        }
        .frame(width: 280)
        .environment(
            \.sidebarLazyContractProbe,
            SidebarLazyContractProbe(
                workspaceRowBody: { workspaceId in
                    counter.workspaceRowBodies += 1
                    counter.realizedWorkspaceIds.insert(workspaceId)
                    counter.insideWorkspaceRowBody = true
                },
                workspaceRowBodyEnd: {
                    counter.insideWorkspaceRowBody = false
                },
                workspaceSnapshotBuild: {
                    counter.workspaceSnapshotBuilds += 1
                }
            )
        )
        .defaultAppStorage(defaults)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        return Harness(
            window: window,
            counter: counter,
            defaults: defaults,
            defaultsSuiteName: defaultsSuiteName
        )
    }

    private static func deterministicWorkspaceID(index: Int) -> UUID {
        let suffix = String(format: "%012X", index + 1)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }

    @MainActor
    private static func noOpActions() -> SidebarWorkspaceRowActions {
        SidebarWorkspaceRowActions(
            select: { _ in },
            setCustomTitle: { _ in },
            clearCustomTitle: {},
            clearCustomDescription: {},
            editDescription: {},
            closeWorkspace: {},
            moveBy: { _ in },
            moveTargetsToTop: { _ in },
            currentWindowMoveTargets: { [] },
            moveTargetsToWindow: { _, _ in },
            moveTargetsToNewWindow: { _ in },
            closeTargets: { _, _ in },
            closeOtherTargets: { _ in },
            closeTargetsBelow: {},
            closeTargetsAbove: {},
            performPin: {},
            createEmptyGroup: {},
            createGroup: { _ in },
            addTargetsToGroup: { _, _ in },
            removeTargetsFromGroup: { _ in },
            reconnectTargets: { _ in },
            disconnectTargets: { _ in },
            applyColor: { _, _ in },
            applyTodoStatus: { _, _ in },
            hideTodoStatus: { _ in },
            requestChecklistAdd: {},
            markRead: { _ in },
            markUnread: { _ in },
            clearLatestNotifications: { _ in },
            openNotification: { _ in },
            copyWorkspaceLinks: { _ in },
            openPullRequest: { _ in },
            openPort: { _ in },
            checklist: SidebarWorkspaceChecklistActions(
                setItemState: { _, _ in },
                removeItem: { _ in },
                addItem: { _ in },
                editItem: { _, _ in },
                moveItem: { _, _ in },
                openPane: {}
            ),
            onDragStart: { NSItemProvider() },
            bonsplitSourceWorkspaceId: { _ in nil },
            moveBonsplitTabToWorkspace: { _, _ in false },
            syncAfterBonsplitDrop: {},
            selectAfterBonsplitDrop: {},
            onToggleChecklistExpansion: {},
            onConsumeChecklistAddFieldActivation: {},
            onChecklistPopoverPresentedChange: { _ in },
            onContextMenuAppear: {},
            onContextMenuDisappear: {},
            onPointerFrameChange: { _ in },
            onPointerFrameDisappear: {}
        )
    }
}
