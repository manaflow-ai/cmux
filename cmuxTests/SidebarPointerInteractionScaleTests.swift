import AppKit
import CmuxSidebar
import CmuxNotifications
import CoreGraphics
import Darwin
import OSLog
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
        // SwiftUI commits hover-driven row updates after the event callback.
        // Wait for that observable work instead of assuming four turns suffice.
        let hoverUpdated = await AppKitTestEventPump().waitUntil(timeout: .seconds(3)) {
            harness.window.contentView?.layoutSubtreeIfNeeded()
            return harness.counter.workspaceRowBodies + harness.counter.groupHeaderBodies > 0
        }
        #expect(hoverUpdated)
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


/// Deterministic regression harness for #8373. The suite keeps the legacy
/// SwiftUI workspace list selected (via SidebarLazyLayoutScaleTests.mountSidebar)
/// because that is the implementation whose LazyVStack/ForEach graph appears in
/// the reporter's stack. The production default is AppKit; this remains as a
/// guard on the fallback and on the identity/snapshot ownership contract.
@Suite(.serialized)
final class SidebarIssue8373StressTests {
    private static let startingWorkspaceCount = 48
    private static let stressIterations = 24
    private static let simultaneousContentTargets = 8

    @MainActor
    private static func renderIDs(_ manager: TabManager) -> [SidebarWorkspaceRenderItemID] {
        let groupsById = Dictionary(
            uniqueKeysWithValues: manager.workspaceGroups.map { ($0.id, $0) }
        )
        // Keep this on the historical two-argument renderItems API so the
        // workload can be applied directly to the 0.64.19 / pre-#8211 source
        // when validating the red side of the regression.
        return SidebarWorkspaceRenderItem.renderItems(
            tabs: manager.tabs,
            groupsById: groupsById
        ).map(\.id)
    }

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

    private static func physicalFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }

    @Test(.timeLimit(.minutes(2)))
    @MainActor
    func groupedScrollMutationStormKeepsIdentityStableAndConverges() async throws {
        let harness = try await SidebarLazyLayoutScaleTests.mountSidebar(
            workspaceCount: Self.startingWorkspaceCount
        )
        defer {
            harness.tearDown()
        }

        // The field reports reproduced around 30-34 workspaces across several
        // groups. Keep this fixture above that size without paying for 160 rows:
        // mountSidebar groups the first 20; group another 16 in fixed chunks so
        // collapse/expand and reorder repeatedly alter visible rows while enough
        // ungrouped workspaces remain for independent content churn.
        let additionalGroupCandidates = Array(
            harness.tabManager.tabs
                .filter { $0.groupId == nil }
                .prefix(16)
                .map(\.id)
        )
        for start in stride(from: 0, to: additionalGroupCandidates.count, by: 4) {
            let end = min(start + 4, additionalGroupCandidates.count)
            _ = harness.tabManager.createWorkspaceGroup(
                name: "Issue 8373 Group \(start / 4 + 5)",
                childWorkspaceIds: Array(additionalGroupCandidates[start..<end]),
                selectAnchor: false,
                collapseSidebarSelection: false
            )
        }
        await SidebarLazyLayoutScaleTests.drainMainRunLoop(for: harness.window, iterations: 30)

        let rootView = try #require(harness.window.contentView)
        let scrollView = try #require(SidebarLazyLayoutScaleTests.firstScrollView(in: rootView))
        let eventPoint = scrollView.convert(
            NSPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY),
            to: nil
        )
        let groupIds = harness.tabManager.workspaceGroups.map(\.id)
        #expect(
            groupIds.count >= 8,
            "The #8373 fixture needs several grouped runs; only \(groupIds.count) groups were created."
        )

        // Keep content churn on stable, ungrouped workspaces. Insert/remove
        // operations use separate workspaces so a content-only phase can prove
        // the ForEach identity sequence stays byte-for-byte identical.
        let contentTargets = Array(
            harness.tabManager.tabs
                .filter { $0.groupId == nil }
                .suffix(Self.simultaneousContentTargets)
        )
        #expect(contentTargets.count == Self.simultaneousContentTargets)

        harness.counter.reset()
        let footprintBefore = Self.physicalFootprintBytes()
        var maximumFootprint = footprintBefore
        let logStart = Date()
        var insertedWorkspaces: [Workspace] = []

        for iteration in 0..<Self.stressIterations {
            let idsBeforeContentMutation = Self.renderIDs(harness.tabManager)
            #expect(Set(idsBeforeContentMutation).count == idsBeforeContentMutation.count)

            // One main-actor turn publishes title and status changes from eight
            // independent workspaces before the run loop is drained. This is
            // the concurrent publisher burst that used to replace row-owned
            // snapshots while LazySubviewPlacements/ForEachState was walking
            // the same live Workspace objects.
            for (offset, workspace) in contentTargets.enumerated() {
                let longTitle = "issue-8373 \(iteration)-\(offset) "
                    + String(repeating: "layout ", count: 10 + (offset % 3))
                _ = workspace.setCustomTitle(
                    iteration.isMultiple(of: 2) ? longTitle : "issue-8373 \(iteration)-\(offset)"
                )
                let key = "issue-8373.status"
                if iteration.isMultiple(of: 2) {
                    workspace.statusEntries[key] = SidebarStatusEntry(
                        key: key,
                        value: "status \(iteration)-\(offset) " + String(repeating: "x", count: 24),
                        icon: "bolt.fill"
                    )
                } else {
                    workspace.statusEntries.removeValue(forKey: key)
                }
            }

            // Sawtooth through the entire document, then deliver one continuous
            // wheel event so each cycle crosses lazy realization/retirement
            // boundaries while the content burst is pending.
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let maximumOffset = max(0, documentHeight - scrollView.contentView.bounds.height)
            let fraction = CGFloat(iteration % 12) / 11
            let requestedOffset = iteration.isMultiple(of: 2)
                ? maximumOffset * fraction
                : maximumOffset * (1 - fraction)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: requestedOffset))
            scrollView.reflectScrolledClipView(scrollView.contentView)

            let scrollPhase: Int64
            switch iteration % 12 {
            case 0: scrollPhase = 1
            case 11: scrollPhase = 4
            default: scrollPhase = 2
            }
            scrollView.scrollWheel(with: try Self.scrollWheelEvent(
                deltaY: iteration.isMultiple(of: 2) ? -64 : 64,
                phase: scrollPhase,
                at: eventPoint,
                window: harness.window
            ))

            await SidebarLazyLayoutScaleTests.drainMainRunLoop(for: harness.window, iterations: 2)

            // Title/status changes may alter row height and contents; they must
            // never alter identity. This specifically audits the id key path
            // visible in the #8373 ForEach.IDGenerator/ForEachState stacks.
            let idsAfterContentMutation = Self.renderIDs(harness.tabManager)
            #expect(
                idsAfterContentMutation == idsBeforeContentMutation,
                "Content-only churn changed the sidebar ForEach identity sequence at iteration \(iteration)."
            )
            #expect(Set(idsAfterContentMutation).count == idsAfterContentMutation.count)

            // Apply one deterministic structural mutation after the content-only
            // identity checkpoint. These changes exercise legitimate collection
            // diffs without mixing them into the identity-stability assertion.
            let groupId = groupIds[iteration % groupIds.count]
            harness.tabManager.toggleWorkspaceGroupCollapsed(groupId: groupId)

            if iteration.isMultiple(of: 3) {
                harness.tabManager.moveWorkspaceGroup(
                    groupId: groupId,
                    toIndex: (iteration * 7) % groupIds.count
                )
            }

            if iteration.isMultiple(of: 4) {
                let workspace = harness.tabManager.addWorkspace(
                    title: "issue-8373 inserted \(iteration)",
                    select: false,
                    autoWelcomeIfNeeded: false,
                    autoRefreshMetadata: false
                )
                insertedWorkspaces.append(workspace)
            } else if iteration % 4 == 2, !insertedWorkspaces.isEmpty {
                let workspace = insertedWorkspaces.removeFirst()
                harness.tabManager.closeWorkspace(workspace, recordHistory: false)
            }

            if iteration % 3 == 1,
               let reorderTarget = harness.tabManager.tabs.reversed().first(where: { candidate in
                   candidate.groupId == nil
                       && !contentTargets.contains(where: { $0.id == candidate.id })
               }) {
                _ = harness.tabManager.reorderWorkspace(
                    tabId: reorderTarget.id,
                    toIndex: max(0, harness.tabManager.tabs.count - 2),
                    isDragOperation: true
                )
            }

            await SidebarLazyLayoutScaleTests.drainMainRunLoop(for: harness.window, iterations: 2)
            maximumFootprint = max(maximumFootprint, Self.physicalFootprintBytes())

            let structuralIDs = Self.renderIDs(harness.tabManager)
            #expect(
                Set(structuralIDs).count == structuralIDs.count,
                "Duplicate sidebar identity appeared after structural mutation at iteration \(iteration)."
            )
        }

        await SidebarLazyLayoutScaleTests.drainMainRunLoop(for: harness.window, iterations: 40)

        let stressSnapshotBuilds = harness.counter.workspaceSnapshotBuilds
        let stressRowInputProjections = harness.counter.workspaceRowInputProjections
        let stressWorkspaceBodies = harness.counter.workspaceRowBodies
        let stressGroupBodies = harness.counter.groupHeaderBodies
        let stressMaxSnapshotsInsideOneRowBody = harness.counter.maxSnapshotBuildsInOneRowBody
        maximumFootprint = max(maximumFootprint, Self.physicalFootprintBytes())
        let footprintGrowth = maximumFootprint >= footprintBefore
            ? maximumFootprint - footprintBefore
            : 0

        let faultMessages = try SidebarLazyLayoutScaleTests.viewUpdateFaultMessages(since: logStart)
        #expect(
            faultMessages.isEmpty,
            """
            #8373 stress emitted \(faultMessages.count) view-update/reentrant-layout faults:
            \(faultMessages.joined(separator: "\n"))
            """
        )

        // This is the deterministic pre-fix red edge. In 0.64.19 TabItemView
        // built/read its live Workspace snapshot inside the lazy row body and
        // subscribed from row lifecycle. #8211 moved that projection above
        // LazyVStack; the exact workload must therefore record zero row-owned
        // snapshot builds.
        #expect(
            stressMaxSnapshotsInsideOneRowBody == 0,
            """
            A lazy row built \(stressMaxSnapshotsInsideOneRowBody) workspace snapshot(s) in one body pass.
            The parent snapshot boundary regressed toward the 0.64.19 #8373 ownership path.
            """
        )

        // Generous ceilings turn a self-sustaining diff/layout loop into a
        // bounded failure while allowing normal whole-list projections caused
        // by legitimate reorder/insert/remove operations.
        #expect(
            stressSnapshotBuilds < 25_000,
            "#8373 stress built \(stressSnapshotBuilds) workspace snapshots."
        )
        #expect(
            stressRowInputProjections < 250_000,
            "#8373 stress projected \(stressRowInputProjections) row inputs."
        )
        #expect(
            stressWorkspaceBodies + stressGroupBodies < 12_000,
            """
            #8373 stress evaluated \(stressWorkspaceBodies) workspace and \(stressGroupBodies) group row bodies.
            Row replacement/layout churn exceeded the bounded contract.
            """
        )
        if footprintBefore > 0, maximumFootprint > 0 {
            #expect(
                footprintGrowth < 768 * 1024 * 1024,
                """
                #8373 stress grew physical footprint by \(footprintGrowth / (1024 * 1024)) MiB.
                The historical failure grew by gigabytes; this workload must remain bounded.
                """
            )
        }

        print(
            "ISSUE_8373_STRESS "
                + "snapshot_builds=\(stressSnapshotBuilds) "
                + "row_input_projections=\(stressRowInputProjections) "
                + "workspace_row_bodies=\(stressWorkspaceBodies) "
                + "group_row_bodies=\(stressGroupBodies) "
                + "max_row_owned_snapshots=\(stressMaxSnapshotsInsideOneRowBody) "
                + "peak_footprint_growth_mib=\(footprintGrowth / (1024 * 1024))"
        )

        // After all input stops, the same hosted list must go quiet. A
        // LazySubviewPlacements/SubgraphList loop keeps evaluating rows here.
        harness.counter.reset()
        await SidebarLazyLayoutScaleTests.drainMainRunLoop(for: harness.window, iterations: 40)
        let quietBodies = harness.counter.workspaceRowBodies + harness.counter.groupHeaderBodies
        #expect(quietBodies < 20, "#8373 sidebar kept evaluating \(quietBodies) rows after input stopped.")
    }
}
