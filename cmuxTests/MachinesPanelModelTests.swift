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
            limits: VMPlanLimits(maxActiveVms: 3, planId: "free")
        )
        XCTAssertEqual(underLimit?.isAtLimit, false)
        XCTAssertEqual(underLimit?.isPaidPlan, false)

        let atLimit = MachineSnapshotBuilder.planSnapshot(
            activeCount: 3,
            limits: VMPlanLimits(maxActiveVms: 3, planId: "free")
        )
        XCTAssertEqual(atLimit?.isAtLimit, true)

        let paid = MachineSnapshotBuilder.planSnapshot(
            activeCount: 4,
            limits: VMPlanLimits(maxActiveVms: 10, planId: "pro")
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

    func testSessionSnapshotMapsCloudSession() {
        let session = VMCloudSession(
            id: "row-1",
            vmId: "vm-1",
            sessionId: "sess-abc",
            title: "build watch",
            kind: "pty",
            status: "running",
            attachmentCount: 2,
            effectiveCols: 120,
            effectiveRows: 40,
            lastKnownCols: nil,
            lastKnownRows: nil,
            scrollbackBytes: 2_048,
            metadata: [:],
            createdAt: "2026-08-25T12:00:00Z",
            updatedAt: "2026-08-25T12:30:00Z",
            lastAttachedAt: nil
        )
        let snapshot = MachineSnapshotBuilder.sessionSnapshot(from: session)
        XCTAssertEqual(snapshot.id, "row-1")
        XCTAssertEqual(snapshot.sessionId, "sess-abc")
        XCTAssertEqual(snapshot.displayName, "build watch")
        XCTAssertEqual(snapshot.attachmentCount, 2)
        XCTAssertEqual(snapshot.scrollbackBytes, 2_048)
        XCTAssertEqual(
            snapshot.createdAt,
            ISO8601DateFormatter().date(from: "2026-08-25T12:00:00Z")
        )
        XCTAssertTrue(snapshot.subtitle.contains("2"))
        XCTAssertTrue(snapshot.subtitle.contains("KB"))
    }

    func testSessionSnapshotFallsBackToSessionIdAndDropsEmptyParts() {
        let session = VMCloudSession(
            id: "row-2",
            vmId: "vm-1",
            sessionId: "sess-def",
            title: nil,
            kind: "pty",
            status: "exited",
            attachmentCount: 0,
            effectiveCols: nil,
            effectiveRows: nil,
            lastKnownCols: nil,
            lastKnownRows: nil,
            scrollbackBytes: 0,
            metadata: [:],
            createdAt: "2026-08-25T12:00:00.250Z",
            updatedAt: "2026-08-25T12:00:00.250Z",
            lastAttachedAt: nil
        )
        let snapshot = MachineSnapshotBuilder.sessionSnapshot(from: session)
        XCTAssertEqual(snapshot.displayName, "sess-def")
        // Fractional-second ISO timestamps parse too.
        XCTAssertNotNil(snapshot.createdAt)
        // Zero attachments and zero scrollback add nothing to the subtitle.
        XCTAssertEqual(snapshot.subtitle, snapshot.statusLabel)
    }

    func testIsoDateRejectsGarbage() {
        XCTAssertNil(MachineSnapshotBuilder.isoDate(nil))
        XCTAssertNil(MachineSnapshotBuilder.isoDate(""))
        XCTAssertNil(MachineSnapshotBuilder.isoDate("yesterday"))
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
}
