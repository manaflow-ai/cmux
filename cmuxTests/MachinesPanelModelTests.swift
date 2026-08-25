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
}
