import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class MachinesPanelModelTests: XCTestCase {
    func testSnapshotMapsSummaryFields() {
        let summary = VMSummary(
            id: "noble-wren",
            provider: "blaxel",
            status: "running",
            image: "blaxel/base-image:latest",
            createdAt: 1_787_400_000_000,
            base: nil
        )
        let snapshot = MachineSnapshotBuilder.snapshot(from: summary)
        XCTAssertEqual(snapshot.id, "noble-wren")
        XCTAssertEqual(snapshot.displayName, "noble-wren")
        XCTAssertNil(snapshot.label)
        XCTAssertEqual(snapshot.provider, "blaxel")
        XCTAssertFalse(snapshot.isDesktop)
        XCTAssertEqual(snapshot.activity, .ready)
        XCTAssertEqual(
            snapshot.createdAt,
            Date(timeIntervalSince1970: 1_787_400_000)
        )
    }

    func testDesktopImageDetection() {
        let desktop = MachineSnapshotBuilder.snapshot(from: VMSummary(
            id: "noble-dolphin",
            provider: "blaxel",
            status: "running",
            image: "blaxel/xfce-vnc:latest",
            createdAt: 0,
            base: nil
        ))
        XCTAssertTrue(desktop.isDesktop)
        XCTAssertNil(desktop.createdAt)
    }

    func testLabelDrivesDisplayName() {
        var summary = VMSummary(
            id: "noble-wren",
            provider: "blaxel",
            status: "running",
            image: "blaxel/base-image:latest",
            createdAt: 0,
            base: nil
        )
        summary.displayName = "dev box"
        let snapshot = MachineSnapshotBuilder.snapshot(from: summary)
        XCTAssertEqual(snapshot.label, "dev box")
        XCTAssertEqual(snapshot.displayName, "dev box")
        XCTAssertEqual(snapshot.id, "noble-wren")
    }

    func testActivityMapping() {
        XCTAssertEqual(MachineSnapshotBuilder.activity(fromStatus: "running"), .ready)
        XCTAssertEqual(MachineSnapshotBuilder.activity(fromStatus: "STANDBY"), .ready)
        XCTAssertEqual(MachineSnapshotBuilder.activity(fromStatus: "creating"), .pending)
        XCTAssertEqual(MachineSnapshotBuilder.activity(fromStatus: "resuming"), .pending)
        XCTAssertEqual(
            MachineSnapshotBuilder.activity(fromStatus: "error"),
            .attention("error")
        )
    }

    func testPlanSnapshotLimitStates() {
        XCTAssertNil(MachineSnapshotBuilder.planSnapshot(activeCount: 1, limits: nil))

        let underLimit = MachineSnapshotBuilder.planSnapshot(
            activeCount: 2,
            limits: VMPlanLimits(maxActiveVms: 3, planId: "free", freeAccessWindowDays: 5)
        )
        XCTAssertEqual(underLimit?.isAtLimit, false)
        XCTAssertEqual(underLimit?.isPaidPlan, false)

        let atLimit = MachineSnapshotBuilder.planSnapshot(
            activeCount: 3,
            limits: VMPlanLimits(maxActiveVms: 3, planId: "free", freeAccessWindowDays: 5)
        )
        XCTAssertEqual(atLimit?.isAtLimit, true)

        let paid = MachineSnapshotBuilder.planSnapshot(
            activeCount: 4,
            limits: VMPlanLimits(maxActiveVms: 10, planId: "pro", freeAccessWindowDays: 0)
        )
        XCTAssertEqual(paid?.isAtLimit, false)
        XCTAssertEqual(paid?.isPaidPlan, true)
    }

    func testMachinesModeIsRegisteredEverywhere() {
        XCTAssertTrue(RightSidebarMode.allCases.contains(.machines))
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "machines"), .machines)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "vms"), .machines)
        XCTAssertFalse(RightSidebarMode.machines.canOpenAsPane)

        // Availability follows the Cloud VM UI flag, independent of feed/dock.
        XCTAssertTrue(
            RightSidebarMode.machines.isAvailable(feedEnabled: false, dockEnabled: false, machinesEnabled: true)
        )
        XCTAssertFalse(
            RightSidebarMode.machines.isAvailable(feedEnabled: true, dockEnabled: true, machinesEnabled: false)
        )
        XCTAssertEqual(
            RightSidebarMode.availableModes(feedEnabled: false, dockEnabled: false, machinesEnabled: true),
            [.files, .find, .sessions, .machines]
        )
        XCTAssertEqual(
            RightSidebarMode.availableModes(feedEnabled: false, dockEnabled: false, machinesEnabled: false),
            [.files, .find, .sessions]
        )
    }

    func testCloudMachinesNeverExposeFleetWhileSignedOut() {
        XCTAssertEqual(
            CloudVMPanelAuthState.resolve(isAuthenticated: false, isWorkingOnAuth: true),
            .checking
        )
        XCTAssertEqual(
            CloudVMPanelAuthState.resolve(isAuthenticated: false, isWorkingOnAuth: false),
            .signedOut
        )
        XCTAssertEqual(
            CloudVMPanelAuthState.resolve(isAuthenticated: true, isWorkingOnAuth: false),
            .signedIn
        )
        XCTAssertFalse(
            CloudVMPanelAuthState.signedOut.allowsAuthenticatedOperation
        )
        XCTAssertTrue(
            CloudVMPanelAuthState.signedIn.allowsAuthenticatedOperation
        )
    }

    func testFreeAccessStateMirrorsTheBackendWindow() {
        let created = Date(timeIntervalSince1970: 1_787_400_000)
        let day: TimeInterval = 86_400

        // Paid plan / disabled window (0 days) never restricts.
        XCTAssertEqual(
            MachineSnapshotBuilder.freeAccessState(createdAt: created, windowDays: 0, now: created.addingTimeInterval(400 * day)),
            .unrestricted
        )
        // Unknown createdAt fails open, matching the backend.
        XCTAssertEqual(
            MachineSnapshotBuilder.freeAccessState(createdAt: nil, windowDays: 5, now: Date()),
            .unrestricted
        )
        // Inside the window: partial days round up so day one reads "5 days left".
        XCTAssertEqual(
            MachineSnapshotBuilder.freeAccessState(createdAt: created, windowDays: 5, now: created.addingTimeInterval(1)),
            .active(daysLeft: 5)
        )
        XCTAssertEqual(
            MachineSnapshotBuilder.freeAccessState(createdAt: created, windowDays: 5, now: created.addingTimeInterval(4.5 * day)),
            .active(daysLeft: 1)
        )
        // Past the window: locked.
        XCTAssertEqual(
            MachineSnapshotBuilder.freeAccessState(createdAt: created, windowDays: 5, now: created.addingTimeInterval(5 * day + 1)),
            .expired
        )
    }

    func testNextFreeAccessTransitionIsTheExactBoundary() {
        let created = Date(timeIntervalSince1970: 1_787_400_000)
        let day: TimeInterval = 86_400

        // Fresh machine: the first label decrement is one day in.
        XCTAssertEqual(
            MachineSnapshotBuilder.nextFreeAccessTransition(createdAt: created, windowDays: 5, now: created.addingTimeInterval(1)),
            created.addingTimeInterval(day)
        )
        // Mid-window: next transition is the next whole-day crossing.
        XCTAssertEqual(
            MachineSnapshotBuilder.nextFreeAccessTransition(createdAt: created, windowDays: 5, now: created.addingTimeInterval(3.5 * day)),
            created.addingTimeInterval(4 * day)
        )
        // Final day: the next transition IS the expiry.
        XCTAssertEqual(
            MachineSnapshotBuilder.nextFreeAccessTransition(createdAt: created, windowDays: 5, now: created.addingTimeInterval(4.5 * day)),
            created.addingTimeInterval(5 * day)
        )
        // Expired or unwindowed: nothing left to wait for.
        XCTAssertNil(
            MachineSnapshotBuilder.nextFreeAccessTransition(createdAt: created, windowDays: 5, now: created.addingTimeInterval(6 * day))
        )
        XCTAssertNil(
            MachineSnapshotBuilder.nextFreeAccessTransition(createdAt: created, windowDays: 0, now: created)
        )
        XCTAssertNil(
            MachineSnapshotBuilder.nextFreeAccessTransition(createdAt: nil, windowDays: 5, now: created)
        )
    }

    func testApplyingFreeAccessRecomputesOnlyThatFacet() {
        let created = 1_787_400_000_000
        let summary = VMSummary(
            id: "noble-wren",
            provider: "blaxel",
            status: "running",
            image: "blaxel/xfce-vnc:latest",
            createdAt: created,
            base: nil
        )
        let createdDate = Date(timeIntervalSince1970: TimeInterval(created) / 1000)
        let before = MachineSnapshotBuilder.snapshot(
            from: summary,
            freeAccessWindowDays: 5,
            now: createdDate.addingTimeInterval(4.9 * 86_400)
        )
        XCTAssertEqual(before.freeAccess, .active(daysLeft: 1))

        let after = MachineSnapshotBuilder.applyingFreeAccess(
            to: [before],
            windowDays: 5,
            now: createdDate.addingTimeInterval(5 * 86_400 + 1)
        )
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].freeAccess, .expired)
        XCTAssertEqual(after[0].id, before.id)
        XCTAssertEqual(after[0].stats, before.stats)
    }

    func testSnapshotCarriesFreeAccessState() {
        let created = 1_787_400_000_000
        let summary = VMSummary(
            id: "noble-wren",
            provider: "blaxel",
            status: "running",
            image: "blaxel/xfce-vnc:latest",
            createdAt: created,
            base: nil
        )
        let now = Date(timeIntervalSince1970: TimeInterval(created) / 1000 + 6 * 86_400)
        let snapshot = MachineSnapshotBuilder.snapshot(from: summary, freeAccessWindowDays: 5, now: now)
        XCTAssertEqual(snapshot.freeAccess, .expired)
        let unrestricted = MachineSnapshotBuilder.snapshot(from: summary, freeAccessWindowDays: 0, now: now)
        XCTAssertEqual(unrestricted.freeAccess, .unrestricted)
    }

    func testFreeAccessCountdownUsesWholeTruncatedUnits() {
        XCTAssertEqual(MachineSnapshotBuilder.freeAccessCountdown(remaining: 6 * 86_400 + 23 * 3_600 + 59 * 60), "6d 23h")
        XCTAssertEqual(MachineSnapshotBuilder.freeAccessCountdown(remaining: 5 * 3_600 + 12 * 60 + 30), "5h 12m")
        XCTAssertEqual(MachineSnapshotBuilder.freeAccessCountdown(remaining: 90), "1m")
        // Never below the floor, never negative.
        XCTAssertEqual(MachineSnapshotBuilder.freeAccessCountdown(remaining: 5), "1m")
    }

    func testFreeAccessBannerStates() {
        let now = Date(timeIntervalSince1970: 1_787_400_000)
        XCTAssertEqual(MachineSnapshotBuilder.freeAccessBanner(expiresAt: now.addingTimeInterval(86_400 * 3), isPaidPlan: true, now: now), .none)
        XCTAssertEqual(MachineSnapshotBuilder.freeAccessBanner(expiresAt: nil, isPaidPlan: false, now: now), .none)
        XCTAssertEqual(
            MachineSnapshotBuilder.freeAccessBanner(expiresAt: now.addingTimeInterval(6 * 86_400 + 23 * 3_600), isPaidPlan: false, now: now),
            .expiresIn(countdown: "6d 23h")
        )
        XCTAssertEqual(
            MachineSnapshotBuilder.freeAccessBanner(expiresAt: now.addingTimeInterval(5 * 3_600 + 12 * 60), isPaidPlan: false, now: now),
            .expiresToday(countdown: "5h 12m")
        )
        XCTAssertEqual(MachineSnapshotBuilder.freeAccessBanner(expiresAt: now.addingTimeInterval(-1), isPaidPlan: false, now: now), .expired)
    }

    func testPlanSnapshotSingularMeterAndServerExpiry() {
        let now = Date(timeIntervalSince1970: 1_787_400_000)
        let serverExpiry = now.addingTimeInterval(2 * 86_400 + 3_600)
        let single = MachineSnapshotBuilder.planSnapshot(
            activeCount: 1,
            limits: VMPlanLimits(
                maxActiveVms: 1,
                planId: "free",
                freeAccessWindowDays: 7,
                freeAccessExpiresAt: Int64(serverExpiry.timeIntervalSince1970 * 1000)
            ),
            now: now
        )
        XCTAssertEqual(single?.isSingleMachinePlan, true)
        XCTAssertEqual(single?.countLabel, "1 of 1 machine")
        XCTAssertEqual(single?.freeAccessExpiresAt, serverExpiry)
        XCTAssertEqual(single?.freeAccessBanner, .expiresIn(countdown: "2d 1h"))

        let plural = MachineSnapshotBuilder.planSnapshot(
            activeCount: 2,
            limits: VMPlanLimits(maxActiveVms: 5, planId: "pro", freeAccessWindowDays: 0),
            now: now
        )
        XCTAssertEqual(plural?.isSingleMachinePlan, false)
        XCTAssertEqual(plural?.countLabel, "2 of 5 machines")
        XCTAssertEqual(plural?.freeAccessBanner, .none)
    }

    func testPlanSnapshotFallsBackToEarliestLocalExpiry() {
        let now = Date(timeIntervalSince1970: 1_787_400_000)
        let created = now.addingTimeInterval(-86_400)
        func machine(_ id: String, createdAt: Date) -> MachineSnapshot {
            MachineSnapshot(
                id: id, provider: "blaxel", image: "blaxel/xfce-vnc:latest", isDesktop: true,
                activity: .ready, createdAt: createdAt, label: nil
            )
        }
        let plan = MachineSnapshotBuilder.planSnapshot(
            activeCount: 2,
            limits: VMPlanLimits(maxActiveVms: 1, planId: "free", freeAccessWindowDays: 7),
            machines: [machine("later", createdAt: created.addingTimeInterval(3_600)), machine("earlier", createdAt: created)],
            now: now
        )
        XCTAssertEqual(plan?.freeAccessExpiresAt, created.addingTimeInterval(7 * 86_400))
        XCTAssertEqual(plan?.freeAccessBanner, .expiresIn(countdown: "6d 0h"))
    }

    func testSnapshotPrefersServerFreeAccessExpiry() {
        let now = Date(timeIntervalSince1970: 1_787_400_000)
        var summary = VMSummary(
            id: "noble-wren", provider: "blaxel", status: "running",
            image: "blaxel/xfce-vnc:latest", createdAt: Int64(now.timeIntervalSince1970 * 1000), base: nil
        )
        summary.freeAccessExpiresAt = Int64(now.addingTimeInterval(-60).timeIntervalSince1970 * 1000)
        // Local window math would say 7 days left; the server says it already closed.
        XCTAssertEqual(MachineSnapshotBuilder.snapshot(from: summary, freeAccessWindowDays: 7, now: now).freeAccess, .expired)
    }
}
