import XCTest

@testable import cmux

@MainActor
final class SidebarColumnDisplayPolicyTests: XCTestCase {
    private let machines = SidebarColumnWidthProfile.machines

    func testRegularDragClampsWithoutModeChange() {
        let resolution = SidebarColumnDisplayPolicy.resolve(
            dragWidth: 200,
            currentMode: .regular,
            profile: machines
        )
        XCTAssertEqual(resolution.mode, .regular)
        XCTAssertEqual(resolution.width, 200)
        XCTAssertEqual(resolution.regularWidth, 200)
        XCTAssertFalse(resolution.didChangeMode)

        let overMax = SidebarColumnDisplayPolicy.resolve(
            dragWidth: 10_000,
            currentMode: .regular,
            profile: machines
        )
        XCTAssertEqual(overMax.width, machines.maximumRegularWidth)
    }

    func testDraggingSlightlyBelowMinimumStaysRegularAtMinimum() {
        // The snap needs deliberate travel: the band between the enter
        // threshold and the minimum clamps like a hard stop.
        let resolution = SidebarColumnDisplayPolicy.resolve(
            dragWidth: machines.minimumRegularWidth - 10,
            currentMode: .regular,
            profile: machines
        )
        XCTAssertEqual(resolution.mode, .regular)
        XCTAssertEqual(resolution.width, machines.minimumRegularWidth)
        XCTAssertFalse(resolution.didChangeMode)
    }

    func testDraggingPastEnterThresholdSnapsToIconRail() {
        let resolution = SidebarColumnDisplayPolicy.resolve(
            dragWidth: machines.iconEnterThreshold - 1,
            currentMode: .regular,
            profile: machines
        )
        XCTAssertEqual(resolution.mode, .icons)
        XCTAssertEqual(resolution.width, machines.railWidth)
        XCTAssertNil(resolution.regularWidth, "The remembered regular width must survive icon mode")
        XCTAssertTrue(resolution.didChangeMode)
    }

    func testIconModeHasHysteresis() {
        // Inside the dead band (between the two thresholds) the rail holds.
        let holding = SidebarColumnDisplayPolicy.resolve(
            dragWidth: machines.iconEnterThreshold + 4,
            currentMode: .icons,
            profile: machines
        )
        XCTAssertEqual(holding.mode, .icons)
        XCTAssertFalse(holding.didChangeMode)

        let exiting = SidebarColumnDisplayPolicy.resolve(
            dragWidth: machines.iconExitThreshold + 1,
            currentMode: .icons,
            profile: machines
        )
        XCTAssertEqual(exiting.mode, .regular)
        XCTAssertEqual(exiting.width, machines.minimumRegularWidth + 1)
        XCTAssertTrue(exiting.didChangeMode)
    }

    func testNonFiniteDragFallsBackSafely() {
        let regular = SidebarColumnDisplayPolicy.resolve(
            dragWidth: .nan,
            currentMode: .regular,
            profile: machines
        )
        XCTAssertEqual(regular.mode, .regular)
        XCTAssertEqual(regular.width, machines.defaultRegularWidth)

        let icons = SidebarColumnDisplayPolicy.resolve(
            dragWidth: .infinity * -1,
            currentMode: .icons,
            profile: machines
        )
        XCTAssertEqual(icons.mode, .icons)
        XCTAssertEqual(icons.width, machines.railWidth)
    }

    func testEffectiveWidthProjectsModes() {
        XCTAssertEqual(
            SidebarColumnDisplayPolicy.effectiveWidth(
                mode: .icons,
                regularWidth: 240,
                profile: machines
            ),
            machines.railWidth
        )
        XCTAssertEqual(
            SidebarColumnDisplayPolicy.effectiveWidth(
                mode: .regular,
                regularWidth: 240,
                profile: machines
            ),
            240
        )
    }

    func testWorkspacesProfileFollowsConfiguredMinimum() {
        let profile = SidebarColumnWidthProfile.workspaces(minimumRegularWidth: 240)
        XCTAssertEqual(profile.iconExitThreshold, 240)
        XCTAssertLessThan(profile.iconEnterThreshold, 240)
        XCTAssertEqual(
            profile.railWidth,
            CGFloat(SessionPersistencePolicy.sidebarColumnIconRailWidth),
            "Both columns share one rail width"
        )
    }

    func testPersistedModeSanitization() {
        XCTAssertEqual(SidebarState.sanitizedColumnMode("icons"), .icons)
        XCTAssertEqual(SidebarState.sanitizedColumnMode("regular"), .regular)
        XCTAssertEqual(SidebarState.sanitizedColumnMode("windows-95"), .regular)
        XCTAssertEqual(SidebarState.sanitizedColumnMode(nil), .regular)
    }

    func testMachinesColumnDefaultSelectionIsLocalAndListsPlacesOnly() throws {
        let manager = TabManager()
        XCTAssertEqual(
            manager.sidebarCreationContextSelection,
            .local,
            "The machines column default is This Mac, not the legacy Automatic mode"
        )
        let snapshots = manager.sidebarCreationContextSnapshots()
        XCTAssertFalse(snapshots.contains { $0.kind == .automatic })
        XCTAssertEqual(snapshots.first?.kind, .local)

        // Legacy automatic ids (old sessions, socket callers) resolve to local.
        XCTAssertTrue(
            manager.selectSidebarCreationContext(
                id: SidebarCreationContextSelection.automaticID
            )
        )
        XCTAssertEqual(manager.sidebarCreationContextSelection, .local)
    }
}
