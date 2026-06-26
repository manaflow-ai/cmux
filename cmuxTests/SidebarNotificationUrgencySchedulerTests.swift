import XCTest
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SidebarNotificationUrgencySchedulerTests: XCTestCase {
    func testSchedulerPrioritizesBlockedThenSmallReadyThenFailed() {
        let now = Date(timeIntervalSince1970: 10_000)
        let failed = snapshot(
            title: "Large refactor",
            unreadCount: 5,
            text: "build failed after large migration",
            createdAt: now.addingTimeInterval(-60)
        )
        let smallReady = snapshot(
            title: "Small bug fix",
            unreadCount: 1,
            text: "tests passed, opened PR for small bug fix",
            createdAt: now.addingTimeInterval(-30)
        )
        let blocked = snapshot(
            title: "Blocked approval",
            unreadCount: 1,
            text: "needs input before continuing",
            createdAt: now
        )

        let ordered = SidebarNotificationUrgencyScheduler.orderedWorkspaceIds(
            snapshots: [failed, smallReady, blocked],
            now: now
        )
        let urgency = SidebarNotificationUrgencyScheduler.urgencyByWorkspaceId(
            snapshots: [failed, smallReady, blocked],
            now: now
        )

        XCTAssertEqual(ordered, [blocked.workspaceId, smallReady.workspaceId, failed.workspaceId])
        XCTAssertEqual(urgency[blocked.workspaceId]?.band, .critical)
        XCTAssertEqual(urgency[blocked.workspaceId]?.reason, .blocked)
        XCTAssertEqual(urgency[smallReady.workspaceId]?.band, .high)
        XCTAssertEqual(urgency[smallReady.workspaceId]?.reason, .ready)
    }

    func testSchedulerAgesOlderOrdinaryUnreadAhead() {
        let now = Date(timeIntervalSince1970: 10_000)
        let newer = snapshot(
            title: "Newer",
            unreadCount: 1,
            text: "new output",
            createdAt: now.addingTimeInterval(-60),
            originalIndex: 0
        )
        let older = snapshot(
            title: "Older",
            unreadCount: 1,
            text: "new output",
            createdAt: now.addingTimeInterval(-90 * 60),
            originalIndex: 1
        )

        let ordered = SidebarNotificationUrgencyScheduler.orderedWorkspaceIds(
            snapshots: [newer, older],
            now: now
        )

        XCTAssertEqual(ordered, [older.workspaceId, newer.workspaceId])
    }

    func testSmallWinsSchedulerPromotesTargetedWork() {
        let now = Date(timeIntervalSince1970: 10_000)
        let failedLarge = snapshot(
            title: "Large migration",
            unreadCount: 5,
            text: "failed after long refactor",
            createdAt: now.addingTimeInterval(-2 * 60 * 60),
            originalIndex: 0
        )
        let tinyFix = snapshot(
            title: "Tiny docs fix",
            unreadCount: 1,
            text: "docs typo update",
            createdAt: now,
            originalIndex: 1
        )

        let ordered = SidebarNotificationUrgencyScheduler.orderedWorkspaceIds(
            snapshots: [failedLarge, tinyFix],
            now: now,
            mode: .smallWins
        )

        XCTAssertEqual(ordered, [tinyFix.workspaceId, failedLarge.workspaceId])
    }

    func testAgingSchedulerUsesOldestUnreadAfterBlockedPriority() {
        let now = Date(timeIntervalSince1970: 10_000)
        let newerFailed = snapshot(
            title: "Newer failure",
            unreadCount: 5,
            text: "failed recently",
            createdAt: now.addingTimeInterval(-60),
            originalIndex: 0
        )
        let olderOrdinary = snapshot(
            title: "Older output",
            unreadCount: 1,
            text: "new output",
            createdAt: now.addingTimeInterval(-2 * 60 * 60),
            originalIndex: 1
        )

        let ordered = SidebarNotificationUrgencyScheduler.orderedWorkspaceIds(
            snapshots: [newerFailed, olderOrdinary],
            now: now,
            mode: .aging
        )

        XCTAssertEqual(ordered, [olderOrdinary.workspaceId, newerFailed.workspaceId])
    }

    func testRoundRobinSchedulerStartsAfterCursor() {
        let now = Date(timeIntervalSince1970: 10_000)
        let first = snapshot(title: "First", unreadCount: 1, text: "new output", createdAt: now, originalIndex: 0)
        let second = snapshot(title: "Second", unreadCount: 1, text: "new output", createdAt: now, originalIndex: 1)
        let third = snapshot(title: "Third", unreadCount: 1, text: "new output", createdAt: now, originalIndex: 2)

        let ordered = SidebarNotificationUrgencyScheduler.orderedWorkspaceIds(
            snapshots: [first, second, third],
            now: now,
            mode: .roundRobin,
            roundRobinCursor: first.workspaceId
        )

        XCTAssertEqual(ordered, [second.workspaceId, third.workspaceId, first.workspaceId])
    }

    func testArrivalOrderSchedulerUsesNotificationArrivalOrder() {
        let now = Date(timeIntervalSince1970: 10_000)
        let newerFailed = snapshot(
            title: "Newer failure",
            unreadCount: 5,
            text: "failed recently",
            createdAt: now,
            originalIndex: 0
        )
        let olderOrdinary = snapshot(
            title: "Older output",
            unreadCount: 1,
            text: "new output",
            createdAt: now.addingTimeInterval(-60),
            originalIndex: 1
        )

        let ordered = SidebarNotificationUrgencyScheduler.orderedWorkspaceIds(
            snapshots: [newerFailed, olderOrdinary],
            now: now,
            mode: .arrivalOrder
        )

        XCTAssertEqual(ordered, [olderOrdinary.workspaceId, newerFailed.workspaceId])
    }

    func testBlockedPriorityAppliesAcrossSchedulerModes() {
        let now = Date(timeIntervalSince1970: 10_000)
        let blocked = snapshot(
            title: "Blocked approval",
            unreadCount: 1,
            text: "needs input before continuing",
            createdAt: now,
            originalIndex: 1
        )
        let olderOrdinary = snapshot(
            title: "Older output",
            unreadCount: 1,
            text: "new output",
            createdAt: now.addingTimeInterval(-2 * 60 * 60),
            originalIndex: 0
        )

        for mode in SidebarNotificationSchedulerMode.allCases {
            let ordered = SidebarNotificationUrgencyScheduler.orderedWorkspaceIds(
                snapshots: [olderOrdinary, blocked],
                now: now,
                mode: mode,
                roundRobinCursor: blocked.workspaceId
            )
            XCTAssertEqual(ordered.first, blocked.workspaceId, "Expected blocked first for \(mode)")
        }
    }

    func testSchedulerIgnoresReadOnlyNotificationText() {
        let now = Date(timeIntervalSince1970: 10_000)
        let readBlocked = snapshot(
            title: "Read blocked",
            unreadCount: 0,
            text: "needs input before continuing",
            createdAt: now
        )

        let urgency = SidebarNotificationUrgencyScheduler.urgency(for: readBlocked, now: now)

        XCTAssertNil(urgency)
    }

    func testSidebarNotificationTextPreservesBaseMessageWithUrgencyPrefix() {
        let now = Date(timeIntervalSince1970: 10_000)
        let blocked = snapshot(
            title: "Blocked approval",
            unreadCount: 1,
            text: "needs input before continuing",
            createdAt: now
        )

        let urgency = SidebarNotificationUrgencyScheduler.urgency(for: blocked, now: now)
        let text = urgency?.sidebarNotificationText("needs input before continuing")

        XCTAssertEqual(urgency?.band.label, "P0")
        XCTAssertEqual(text, "P0 Blocked: needs input before continuing")
    }

    private func snapshot(
        title: String,
        unreadCount: Int,
        text: String?,
        createdAt: Date?,
        originalIndex: Int = 0
    ) -> SidebarNotificationSchedulerSnapshot {
        SidebarNotificationSchedulerSnapshot(
            workspaceId: UUID(),
            originalIndex: originalIndex,
            unreadCount: unreadCount,
            latestNotificationText: text,
            latestNotificationCreatedAt: createdAt,
            latestNotificationIsUnread: unreadCount > 0,
            workspaceTitle: title,
            customDescription: nil,
            latestSubmittedMessage: nil,
            remoteDisplayTarget: nil,
            remoteConnectionState: nil,
            panelCount: 1
        )
    }
}
