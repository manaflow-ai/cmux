import AppKit
import CmuxSidebar
import CoreGraphics
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
