import Foundation
import Bonsplit
import Testing
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

    func testBakedDevboxImageIsDesktop() {
        let devbox = MachineSnapshotBuilder.snapshot(from: VMSummary(
            id: "vivid-heron",
            provider: "blaxel",
            status: "running",
            image: "sandbox/cmux-devbox:latest",
            createdAt: 0,
            base: nil
        ))
        XCTAssertTrue(devbox.isDesktop)
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
        let created: Int64 = 1_787_400_000_000
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
        let created: Int64 = 1_787_400_000_000
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
        XCTAssertEqual(plural?.freeAccessBanner, MachinePlanSnapshot.FreeAccessBanner.none)
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

    // MARK: - Cloud tree
    private func machineSnapshot(id: String, image: String = "blaxel/xfce-vnc:latest") -> MachineSnapshot {
        MachineSnapshotBuilder.snapshot(from: VMSummary(
            id: id, provider: "blaxel", status: "running", image: image, createdAt: 0, base: nil
        ))
    }

    private func machineInfo(
        _ id: SurfaceMachineID,
        name: String? = nil,
        linkState: SurfaceLinkState = .connected,
        linkError: String? = nil,
        hasDesktop: Bool = true,
        remoteWorkspaces: [SurfaceRemoteWorkspace]? = nil
    ) -> SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: id, name: name ?? id.rawValue, status: "running", image: hasDesktop ? "blaxel/xfce-vnc:latest" : "blaxel/base-image:latest",
            hasDesktop: hasDesktop, memoryMb: nil, diskMb: nil, linkState: linkState, linkError: linkError,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil, remoteWorkspaces: remoteWorkspaces
        )
    }

    private func terminal(
        _ machine: SurfaceMachineID, _ key: String, title: String = "shell", cwd: String? = "/root",
        lifecycle: SurfaceLifecycle = .running, workspace: SurfaceRemoteWorkspace? = nil, agent: SurfaceAgentBadge? = nil
    ) -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: key), title: title, detail: cwd,
            lifecycle: lifecycle, agent: agent, remoteWorkspace: workspace, port: nil, url: nil
        )
    }

    func testCloudTreePoolsThenWorkspacePointerLists() {
        let ws0 = SurfaceRemoteWorkspace(id: "ws_main", name: "main", index: 0, focused: true)
        let ws1 = SurfaceRemoteWorkspace(id: "ws_side", name: "side", index: 1, focused: false)
        let wsEmpty = SurfaceRemoteWorkspace(id: "ws_empty", name: "scratch", index: 2, focused: false)
        let local = UUID()
        let localTerminal = terminal(.local, "AAA", title: "zsh", cwd: "/Users/me")
        // term_1 has two views (ws_main and ws_side); term_2 has zero views (pool only).
        var remoteA = terminal(.cloud("vivid-newt"), "term_1", title: "cargo test", cwd: "/root/app", workspace: ws0, agent: SurfaceAgentBadge(state: "running", source: "claude"))
        remoteA.remoteViews = [SurfaceRemoteView(tabID: "tab_1", workspace: ws0), SurfaceRemoteView(tabID: "tab_9", workspace: ws1)]
        var remoteB = terminal(.cloud("vivid-newt"), "term_2", title: "zsh", cwd: nil, lifecycle: .exited)
        remoteB.remoteViews = []
        var display = SurfaceResource(id: SurfaceResourceID(machine: .cloud("vivid-newt"), kind: .display, key: "display:1"), title: "Desktop", detail: nil, lifecycle: .running, agent: nil, remoteWorkspace: nil, port: 6901, url: nil)
        // ws_side also points at the machine's screen (a display tab in the daemon).
        display.remoteViews = [SurfaceRemoteView(tabID: "tab_desk", workspace: ws1)]
        let port = SurfaceResource(id: SurfaceResourceID(machine: .cloud("vivid-newt"), kind: .browser, key: "port:3000"), title: ":3000", detail: "http", lifecycle: .running, agent: nil, remoteWorkspace: nil, port: 3000, url: nil)
        let snapshot = SurfaceCatalogSnapshot(
            machines: [machineInfo(.local, name: "Austin's Mac"), machineInfo(.cloud("vivid-newt"), remoteWorkspaces: [ws0, ws1, wsEmpty])],
            resources: [remoteA, remoteB, display, port, localTerminal],
            projections: [
                SurfaceProjection(resource: localTerminal.id, workspaceID: local, panelID: UUID()),
                SurfaceProjection(resource: remoteB.id, workspaceID: local, panelID: UUID()),
            ]
        )
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [machineSnapshot(id: "vivid-newt")],
            snapshot: snapshot,
            localWorkspaces: [CloudTreeLocalWorkspace(id: local, title: "cmux90", isSelected: true)],
            includeLocalMachine: true
        )
        let ids = CloudTreeNodeBuilder.flattened(nodes).map(\.id)
        XCTAssertEqual(ids, [
            "machine:local",
            "machine:local/ws/\(local.uuidString)",
            "resource:local/terminal/AAA",
            "machine:vivid-newt",
            "machine:vivid-newt/terminals",
            "resource:vivid-newt/terminal/term_1",
            "resource:vivid-newt/terminal/term_2",
            "machine:vivid-newt/displays",
            "resource:vivid-newt/display/display:1",
            "machine:vivid-newt/workspaces",
            "machine:vivid-newt/ws/ws_main",
            "machine:vivid-newt/ws/ws_main/resource:vivid-newt/terminal/term_1",
            "machine:vivid-newt/ws/ws_main/resource:vivid-newt/display/display:1",
            "machine:vivid-newt/ws/ws_side",
            "machine:vivid-newt/ws/ws_side/resource:vivid-newt/terminal/term_1",
            "machine:vivid-newt/ws/ws_side/resource:vivid-newt/display/display:1",
            "machine:vivid-newt/ws/ws_empty",
            "machine:vivid-newt/ws/ws_empty/resource:vivid-newt/display/display:1",
        ])
        // A remote workspace already showing locally: its row marks it open and the click
        // jumps to that local workspace instead of opening a second copy.
        let openSnapshot = SurfaceCatalogSnapshot(
            machines: snapshot.machines,
            resources: snapshot.resources,
            projections: snapshot.projections + [SurfaceProjection(resource: remoteA.id, workspaceID: local, panelID: UUID())]
        )
        let openNodes = CloudTreeNodeBuilder.nodes(
            machines: [machineSnapshot(id: "vivid-newt")],
            snapshot: openSnapshot,
            localWorkspaces: [CloudTreeLocalWorkspace(id: local, title: "cmux90", isSelected: true)],
            includeLocalMachine: true
        )
        let openByID = Dictionary(CloudTreeNodeBuilder.flattened(openNodes).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if case .workspace(_, _, _, let openIn) = openByID["machine:vivid-newt/ws/ws_main"]!.kind {
            XCTAssertEqual(openIn, local, "term_1's pane lives in the local workspace")
        } else { XCTFail("expected ws_main row") }
        if case .workspace(_, _, _, let openIn) = openByID["machine:vivid-newt/ws/ws_empty"]!.kind {
            XCTAssertNil(openIn, "nothing of it is open anywhere")
        } else { XCTFail("expected ws_empty row") }
        // Desktop rows: a workspace's own display pointer opens inside the local
        // workspace showing that remote workspace; the pool row keeps the global jump.
        if case .display(_, let openIn) = openByID["machine:vivid-newt/ws/ws_main/resource:vivid-newt/display/display:1"]!.kind {
            XCTAssertEqual(openIn, local, "ws_main shows locally, so its Desktop opens there")
        } else { XCTFail("expected ws_main display row") }
        if case .display(_, let openIn) = openByID["resource:vivid-newt/display/display:1"]!.kind {
            XCTAssertNil(openIn, "the pool Desktop keeps the global open-or-focus")
        } else { XCTFail("expected pool display row") }
        if case .display(_, let openIn) = openByID["machine:vivid-newt/ws/ws_empty/resource:vivid-newt/display/display:1"]!.kind {
            XCTAssertNil(openIn, "ws_empty shows nowhere locally")
        } else { XCTFail("expected ws_empty display row") }
        XCTAssertNil(CloudTreeNodeBuilder.localWorkspaceShowing([], snapshot: openSnapshot))
        // The workspace's open/drag group carries its display pointer with its terminals.
        XCTAssertEqual(
            CloudTreeNodeBuilder.flattened(nodes).first { $0.id == "machine:vivid-newt/ws/ws_side" }?.dragGroup?.resources,
            [remoteA.id, display.id]
        )
        // An implicit display row (no view pins it) shows under the workspace but
        // stays out of the workspace's open/drag group.
        XCTAssertEqual(
            CloudTreeNodeBuilder.flattened(nodes).first { $0.id == "machine:vivid-newt/ws/ws_main" }?.dragGroup?.resources,
            [remoteA.id]
        )
        XCTAssertFalse(ids.contains { $0.contains("port") }, "ports stay out of the tree for now")
        let flattened = CloudTreeNodeBuilder.flattened(nodes)
        let byID = Dictionary(flattened.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Pool rows carry the view badge; open markers come from the catalog's projections.
        if case .terminal(let row) = byID["resource:vivid-newt/terminal/term_1"]!.kind {
            XCTAssertFalse(row.isOpen)
            XCTAssertEqual(row.viewBadge, 2)
            XCTAssertEqual(row.resource.agent?.source, "claude")
        } else { XCTFail("expected term_1 pool row") }
        if case .terminal(let row) = byID["resource:vivid-newt/terminal/term_2"]!.kind {
            XCTAssertTrue(row.isOpen)
            XCTAssertEqual(row.viewBadge, 0, "zero views = alive in the pool, in no workspace")
        } else { XCTFail("expected term_2 pool row") }
        // Pointer rows have workspace-scoped identity and no badge.
        if case .terminal(let row) = byID["machine:vivid-newt/ws/ws_side/resource:vivid-newt/terminal/term_1"]!.kind {
            XCTAssertNil(row.viewBadge)
            XCTAssertEqual(row.resource.id.key, "term_1")
        } else { XCTFail("expected pointer row") }
        // The empty workspace still gets a row (from the machine info), with no pointers.
        if case .workspace(_, let workspace, let count, _) = byID["machine:vivid-newt/ws/ws_empty"]!.kind {
            XCTAssertEqual(workspace.name, "scratch")
            XCTAssertEqual(count, 0)
        } else { XCTFail("expected empty workspace row") }
        if case .terminalsPool(_, let count) = byID["machine:vivid-newt/terminals"]!.kind {
            XCTAssertEqual(count, 2)
        } else { XCTFail("expected terminals pool") }
        if case .localMachine(let row) = flattened[0].kind {
            XCTAssertEqual(row.name, "Austin's Mac"); XCTAssertEqual(row.terminalCount, 1); XCTAssertEqual(row.browserCount, 0)
        } else { XCTFail("expected This Mac first") }
        if case .localWorkspace(let row) = flattened[1].kind { XCTAssertEqual(row.title, "cmux90"); XCTAssertTrue(row.isSelected) } else { XCTFail("expected local workspace") }
        XCTAssertEqual(flattened.compactMap { $0.dragResource?.id.rawValue }, [
            "local/terminal/AAA",
            "vivid-newt/terminal/term_1", "vivid-newt/terminal/term_2",
            "vivid-newt/display/display:1",
            "vivid-newt/terminal/term_1", "vivid-newt/display/display:1",
            "vivid-newt/terminal/term_1", "vivid-newt/display/display:1",
            "vivid-newt/display/display:1",
        ], "pool rows, then one drag resource per pointer (or implicit display) row")
        XCTAssertTrue(flattened[0].isMachineRow)
        XCTAssertTrue(flattened[3].isMachineRow)
        XCTAssertEqual(flattened[3].machine, .cloud("vivid-newt"))
        // Only terminals and displays leave the tree by drag; workspaces,
        // browsers, machines, and headers do not.
        for node in flattened {
            switch node.kind {
            case .terminal, .display:
                XCTAssertTrue(node.isDragSource, "\(node.id) should drag")
            default:
                XCTAssertFalse(node.isDragSource, "\(node.id) should not drag")
            }
        }
    }

    func testCloudTreeLocalBrowsersGroupAndEmptyLocalPlaceholder() {
        let browser = SurfaceResource(id: SurfaceResourceID(machine: .local, kind: .browser, key: "BBB"), title: "Docs", detail: nil, lifecycle: .running, agent: nil, remoteWorkspace: nil, port: nil, url: "https://cmux.com/docs")
        let local = UUID()
        let snapshot = SurfaceCatalogSnapshot(
            machines: [machineInfo(.local)],
            resources: [browser],
            projections: [SurfaceProjection(resource: browser.id, workspaceID: local, panelID: UUID())]
        )
        let nodes = CloudTreeNodeBuilder.nodes(machines: [], snapshot: snapshot, localWorkspaces: [CloudTreeLocalWorkspace(id: local, title: "web", isSelected: false)], includeLocalMachine: true)
        let ids = CloudTreeNodeBuilder.flattened(nodes).map(\.id)
        XCTAssertEqual(ids, ["machine:local", "machine:local/placeholder", "machine:local/browsers", "resource:local/browser/BBB"])
        if case .browser(let row) = CloudTreeNodeBuilder.flattened(nodes)[3].kind {
            XCTAssertTrue(row.isOpen)
            XCTAssertEqual(row.workspaceTitle, "web")
            XCTAssertEqual(CloudTreeBrowserDetail.text(for: row), "cmux.com")
        } else { XCTFail("expected browser row") }
    }

    func testCloudTreeSleepingAndBrokenMachinesShowOnePlaceholder() {
        let asleep = CloudTreeNodeBuilder.nodes(
            machines: [machineSnapshot(id: "quiet-owl", image: "blaxel/base-image:latest")],
            snapshot: SurfaceCatalogSnapshot(machines: [machineInfo(.cloud("quiet-owl"), linkState: .asleep, hasDesktop: false)], resources: [], projections: []),
            localWorkspaces: []
        )
        XCTAssertEqual(CloudTreeNodeBuilder.flattened(asleep).map(\.id), ["machine:quiet-owl", "machine:quiet-owl/placeholder"])
        if case .placeholder(_, let placeholder) = asleep[0].children[0].kind { XCTAssertEqual(placeholder.style, .dimmed) } else { XCTFail() }

        let broken = CloudTreeNodeBuilder.nodes(
            machines: [machineSnapshot(id: "broken-elk")],
            snapshot: SurfaceCatalogSnapshot(machines: [machineInfo(.cloud("broken-elk"), linkState: .error, linkError: "timed out", hasDesktop: false)], resources: [], projections: []),
            localWorkspaces: []
        )
        if case .placeholder(_, let placeholder) = broken[0].children[0].kind {
            XCTAssertEqual(placeholder.style, .error)
            XCTAssertEqual(placeholder.text, "timed out")
        } else { XCTFail() }
        // A machine the catalog has not registered yet has nothing to expand.
        XCTAssertNil(CloudTreeNodeBuilder.nodes(machines: [machineSnapshot(id: "new")], snapshot: .empty, localWorkspaces: [])[0].children.first)
        // A machine only the catalog knows still gets a row.
        let catalogOnly = CloudTreeNodeBuilder.nodes(
            machines: [],
            snapshot: SurfaceCatalogSnapshot(machines: [machineInfo(.cloud("ghost"))], resources: [], projections: []),
            localWorkspaces: []
        )
        XCTAssertEqual(catalogOnly.map(\.id), ["machine:ghost"])
    }

    func testSurfaceResourceDragRecordRoundTripsAndNamesEveryResource() throws {
        let port = SurfaceResourceID(machine: .cloud("vivid-newt"), kind: .browser, key: "port:8000")
        let term = SurfaceResourceID(machine: .cloud("vivid-newt"), kind: .terminal, key: "term_1")
        let record = SurfaceResourceDragPasteboardRecord(dragID: UUID(), resources: [term.rawValue, port.rawValue], title: "main")
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(SurfaceResourceDragPasteboardRecord.self, from: data)
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.resourceIDs, [term, port], "open order is preserved")
        XCTAssertEqual(decoded.title, "main")
        XCTAssertEqual(CloudTreeTerminalRowContent.abbreviated("/root/app"), "~/app")
        // A cloud machine's user home reads as `~` too (`/home/cua` on the devbox image).
        XCTAssertEqual(CloudTreeTerminalRowContent.abbreviated("/home/cua"), "~")
        XCTAssertEqual(CloudTreeTerminalRowContent.abbreviated("/home/cua/work/app"), "~/work/app")
        XCTAssertEqual(CloudTreeTerminalRowContent.abbreviated("/home"), "/home")
        XCTAssertEqual(CloudTreeTerminalRowContent.abbreviated("/homer/cua"), "/homer/cua")
        XCTAssertEqual(CloudTreeTerminalRowContent.abbreviated("/var/home/cua"), "/var/home/cua")
    }

    func testWorkspaceRowsDragTheirWholeCollectionTerminalsThenBrowsers() {
        let ws0 = SurfaceRemoteWorkspace(id: "ws_main", name: "main", index: 0, focused: true)
        let ws1 = SurfaceRemoteWorkspace(id: "ws_side", name: "side", index: 1, focused: false)
        let termB = terminal(.cloud("m"), "term_b", workspace: ws0)
        let termA = terminal(.cloud("m"), "term_a", workspace: ws0)
        let termSide = terminal(.cloud("m"), "term_side", workspace: ws1)
        var browserMain = SurfaceResource(id: SurfaceResourceID(machine: .cloud("m"), kind: .browser, key: "browser_1"), title: "Docs", detail: nil, lifecycle: .running, agent: nil, remoteWorkspace: ws0, port: nil, url: "https://x.y")
        browserMain.remoteWorkspace = ws0
        let local = UUID(), other = UUID()
        let localTerm = terminal(.local, "AAA", title: "zsh")
        let localTerm2 = terminal(.local, "BBB", title: "fish")
        let localBrowser = SurfaceResource(id: SurfaceResourceID(machine: .local, kind: .browser, key: "CCC"), title: "Web", detail: nil, lifecycle: .running, agent: nil, remoteWorkspace: nil, port: nil, url: "https://cmux.com")
        let snapshot = SurfaceCatalogSnapshot(
            machines: [machineInfo(.local), machineInfo(.cloud("m"), hasDesktop: false)],
            resources: [browserMain, termSide, termB, termA, localTerm2, localTerm, localBrowser],
            projections: [
                SurfaceProjection(resource: localTerm.id, workspaceID: local, panelID: UUID()),
                SurfaceProjection(resource: localBrowser.id, workspaceID: local, panelID: UUID()),
                SurfaceProjection(resource: localTerm2.id, workspaceID: other, panelID: UUID()),
            ]
        )
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [machineSnapshot(id: "m", image: "blaxel/base-image:latest")],
            snapshot: snapshot,
            localWorkspaces: [CloudTreeLocalWorkspace(id: local, title: "cmux90", isSelected: true), CloudTreeLocalWorkspace(id: other, title: "notes", isSelected: false)],
            includeLocalMachine: true
        )
        let flattened = CloudTreeNodeBuilder.flattened(nodes)
        let byID = Dictionary(flattened.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // A cmux-tui workspace row drags every resource of that workspace: terminals first, then browsers.
        let main = byID["machine:m/ws/ws_main"]!
        XCTAssertEqual(main.dragGroup?.title, "main")
        XCTAssertEqual(main.dragGroup?.resources, [termB.id, termA.id, browserMain.id], "terminals in catalog order, then the workspace's browsers")
        XCTAssertEqual(byID["machine:m/ws/ws_side"]!.dragGroup?.resources, [termSide.id])
        // A local workspace row drags the panes it projects (terminal, then browser).
        XCTAssertEqual(byID["machine:local/ws/\(local.uuidString)"]!.dragGroup?.resources, [localTerm.id, localBrowser.id])
        XCTAssertEqual(byID["machine:local/ws/\(other.uuidString)"]!.dragGroup?.resources, [localTerm2.id])
        // Leaves are one-element groups; headers and machines are not draggable.
        XCTAssertEqual(byID["resource:m/terminal/term_a"]!.dragGroup?.resources, [termA.id])
        XCTAssertNil(byID["machine:m"]!.dragGroup)
        XCTAssertNil(byID["machine:local"]!.dragGroup)
        XCTAssertNil(byID["machine:m/workspaces"]!.dragGroup)
    }

    @MainActor
    private final class GroupFakeProvider: SurfaceProvider {
        let machine: SurfaceMachineID
        var info: SurfaceMachineInfo
        var materialized: [(SurfaceResourceID, SurfaceDestination, Bool)] = []
        init(machine: SurfaceMachineID) {
            self.machine = machine
            info = SurfaceMachineInfo(id: machine, name: machine.rawValue, status: "running", image: nil, hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil)
        }
        func refresh() async {}
        func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
            materialized.append((resource.id, destination, focus))
            return SurfaceProjection(resource: resource.id, workspaceID: destination.workspaceID, panelID: UUID())
        }
        func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
            SurfaceResource(id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_new"), title: "shell", detail: nil, lifecycle: .launching, agent: nil, remoteWorkspace: nil, port: nil, url: nil)
        }
        func projectionDidEnd(_ projection: SurfaceProjection) {}
    }

    @MainActor
    func testProjectGroupLandsTheFirstAtTheDropAndTheRestAsTabsOfThatPane() async throws {
        let catalog = SurfaceCatalog()
        let provider = GroupFakeProvider(machine: .cloud("m"))
        catalog.register(provider)
        let a = terminal(.cloud("m"), "term_a"), b = terminal(.cloud("m"), "term_b")
        let browser = SurfaceResource(id: SurfaceResourceID(machine: .cloud("m"), kind: .browser, key: "port:3000"), title: ":3000", detail: nil, lifecycle: .running, agent: nil, remoteWorkspace: nil, port: 3000, url: nil)
        catalog.replaceResources([a, b, browser], on: .cloud("m"))
        let ws = UUID()
        let missing = SurfaceResourceID(machine: .cloud("m"), kind: .terminal, key: "term_gone")
        let drop = SurfaceDestination.split(workspaceID: ws, paneID: "pane-drop", direction: .left)

        let projected = try await catalog.projectGroup([a.id, missing, b.id, browser.id], into: drop, focus: true) { panelID, workspaceID in
            XCTAssertEqual(workspaceID, ws)
            return "pane-of-\(panelID.uuidString.prefix(4))"
        }
        XCTAssertEqual(projected.map(\.resource), [a.id, b.id, browser.id], "the unknown resource is skipped, order kept")
        XCTAssertEqual(provider.materialized.count, 3)
        XCTAssertEqual(provider.materialized[0].1, drop)
        XCTAssertTrue(provider.materialized[0].2, "only the first pane takes focus")
        let leadPane = "pane-of-\(projected[0].panelID.uuidString.prefix(4))"
        XCTAssertEqual(provider.materialized[1].1, .tab(workspaceID: ws, paneID: leadPane, index: nil))
        XCTAssertEqual(provider.materialized[2].1, .tab(workspaceID: ws, paneID: leadPane, index: nil))
        XCTAssertFalse(provider.materialized[1].2)
        XCTAssertEqual(catalog.projections(of: a.id).count, 1)

        // Without a resolvable pane the rest still join the lead workspace as tabs.
        let again = try await catalog.projectGroup([a.id, b.id], into: .workspace(id: ws, placement: .split), focus: false) { _, _ in nil }
        XCTAssertEqual(again.count, 2)
        XCTAssertEqual(provider.materialized[4].1, .workspace(id: ws, placement: .tab))
        XCTAssertEqual(catalog.projections(of: a.id).count, 2, "a drop never reuses a pane elsewhere")

        // Nothing projectable → the first error surfaces.
        do {
            _ = try await catalog.projectGroup([missing], into: drop, focus: true) { _, _ in nil }
            XCTFail("expected unknownResource")
        } catch {
            XCTAssertEqual(error as? SurfaceCatalogError, .unknownResource(missing))
        }
    }

    @MainActor
    func testCloudTreeExpansionStoreDefaultsToExpandedAndPersistsMachineCollapse() {
        let defaults = UserDefaults(suiteName: "CloudTreeExpansionStoreTests-\(UUID().uuidString)")!
        let store = CloudTreeExpansionStore(defaults: defaults)
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [machineSnapshot(id: "vivid-newt")],
            snapshot: SurfaceCatalogSnapshot(machines: [machineInfo(.local), machineInfo(.cloud("vivid-newt"))], resources: [terminal(.cloud("vivid-newt"), "term_1")], projections: []),
            localWorkspaces: [],
            includeLocalMachine: true
        )
        let localNode = nodes[0], machineNode = nodes[1], group = machineNode.children[0]
        XCTAssertTrue(store.isExpanded(localNode))
        XCTAssertTrue(store.isExpanded(machineNode))
        XCTAssertTrue(store.isExpanded(group))
        store.setExpanded(false, node: machineNode)
        store.setExpanded(false, node: localNode)
        store.setExpanded(false, node: group)
        let reloaded = CloudTreeExpansionStore(defaults: defaults)
        XCTAssertFalse(reloaded.isExpanded(machineNode), "machine collapse persists")
        XCTAssertFalse(reloaded.isExpanded(localNode), "This Mac's collapse persists too")
        XCTAssertTrue(reloaded.isExpanded(group), "nested collapses are panel-lifetime only")
    }

    func testMachineSubtitleNeverShowsTheFreeAccessCountdown() {
        let active = MachineSnapshot(
            id: "warm-owl", provider: "blaxel", image: "blaxel/xfce-vnc:latest", isDesktop: true,
            activity: .ready, createdAt: nil, label: nil, freeAccess: .active(daysLeft: 3)
        )
        XCTAssertFalse(CloudTreeMachineRowContent.subtitle(active).contains("3"), "expiry is plan chrome, not a machine fact")
        XCTAssertNil(CloudTreeMachineRowContent.inlineFact(active, style: .compact))

        let expired = MachineSnapshot(
            id: "warm-owl", provider: "blaxel", image: "blaxel/xfce-vnc:latest", isDesktop: true,
            activity: .attention("locked"), createdAt: nil, label: nil, freeAccess: .expired
        )
        XCTAssertTrue(CloudTreeMachineRowContent.subtitle(expired).contains("Locked"), "a dead row still explains itself")
        XCTAssertNotNil(CloudTreeMachineRowContent.inlineFact(expired, style: .compact))
    }

    func testCloudTreeStylePresetsAreDistinctAndResolvable() {
        let presets = CloudTreeStyle.presets
        XCTAssertEqual(presets.count, 5)
        XCTAssertEqual(Set(presets.map(\.id)).count, presets.count, "preset ids are unique")
        for preset in presets {
            XCTAssertEqual(CloudTreeStyle.preset(id: preset.id), preset)
            XCTAssertGreaterThan(preset.rowHeight, 0)
            XCTAssertGreaterThanOrEqual(preset.machineRowHeight(hasStats: true), preset.machineRowHeight(hasStats: false))
            XCTAssertGreaterThan(preset.machineRowHeight(hasStats: false), 0)
        }
        XCTAssertEqual(CloudTreeStyle.defaultStyle, .compact, "the default is the compact variant")
        XCTAssertNil(CloudTreeStyle.preset(id: "bogus"))
        // The presets are different shapes, not one look at five sizes.
        XCTAssertEqual(Set(presets.map { "\($0.leafLayout)|\($0.iconTreatment)|\($0.groupLabelStyle)|\($0.metaPlacement)|\($0.machineBand)|\($0.monospacedText)" }).count, presets.count, "every preset differs structurally")
        // Two-line cards grow with the stats line; single-line rows never do.
        XCTAssertGreaterThan(CloudTreeStyle.aero.machineRowHeight(hasStats: true), CloudTreeStyle.aero.machineRowHeight(hasStats: false))
        XCTAssertEqual(CloudTreeStyle.compact.machineRowHeight(hasStats: true), CloudTreeStyle.compact.machineRowHeight(hasStats: false))
    }

    func testDropDestinationMapsEverySplitSideAndInserts() {
        let workspace = UUID()
        let pane = PaneID(id: UUID())
        func destination(_ bonsplit: BonsplitController.ExternalTabDropRequest.Destination) -> SurfaceDestination {
            SurfaceDestination.dropDestination(workspaceID: workspace, destination: bonsplit)
        }
        XCTAssertEqual(destination(.split(targetPane: pane, orientation: .horizontal, insertFirst: true)), .split(workspaceID: workspace, paneID: pane.id.uuidString, direction: .left))
        XCTAssertEqual(destination(.split(targetPane: pane, orientation: .horizontal, insertFirst: false)), .split(workspaceID: workspace, paneID: pane.id.uuidString, direction: .right))
        XCTAssertEqual(destination(.split(targetPane: pane, orientation: .vertical, insertFirst: true)), .split(workspaceID: workspace, paneID: pane.id.uuidString, direction: .up))
        XCTAssertEqual(destination(.split(targetPane: pane, orientation: .vertical, insertFirst: false)), .split(workspaceID: workspace, paneID: pane.id.uuidString, direction: .down))
        XCTAssertEqual(destination(.insert(targetPane: pane, targetIndex: 2)), .tab(workspaceID: workspace, paneID: pane.id.uuidString, index: 2))
        XCTAssertEqual(destination(.insert(targetPane: pane, targetIndex: nil)).workspaceID, workspace)
    }
}


/// The Cloud tab shows this Mac by default (cloud-only stays one flip away), and the
/// outline updates rows in place unless the tree's structure changed.
@MainActor
final class CloudTreeScopeAndSignatureTests: XCTestCase {
    func testMachineCapabilitiesDecodeWithSupportedDefaults() {
        XCTAssertEqual(VMCapabilities(json: nil), .all, "an older control plane supports everything")
        XCTAssertEqual(VMCapabilities(json: ["snapshot": false, "fork": false]), VMCapabilities(snapshot: false, restore: true, fork: false))
        XCTAssertEqual(VMCapabilities(json: ["snapshot": NSNumber(value: false), "restore": NSNumber(value: true), "fork": true]),
                       VMCapabilities(snapshot: false, restore: true, fork: true))
        let summary = VMSummary(id: "m", provider: "blaxel", status: "running", image: "sandbox/cmux-devbox:latest", createdAt: 0, base: nil)
        XCTAssertEqual(summary.capabilities, .all)
        var declared = summary
        declared.capabilities = VMCapabilities(json: ["snapshot": false, "restore": false, "fork": false])
        XCTAssertFalse(declared.capabilities.snapshot)
    }

    private func terminal(_ machine: SurfaceMachineID, _ key: String, title: String = "shell", cwd: String? = "/root") -> SurfaceResource {
        SurfaceResource(id: SurfaceResourceID(machine: machine, kind: .terminal, key: key), title: title, detail: cwd, lifecycle: .running, agent: nil, remoteWorkspace: SurfaceRemoteWorkspace(id: "ws_0", name: "0", index: 0, focused: true), port: nil, url: nil)
    }

    private func info(_ machine: SurfaceMachineID) -> SurfaceMachineInfo {
        SurfaceMachineInfo(id: machine, name: machine.rawValue, status: "running", image: "blaxel/xfce-vnc:latest", hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: machine.isLocal ? .notApplicable : .connected, linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil)
    }

    private func machine(_ id: String) -> MachineSnapshot {
        MachineSnapshot(id: id, provider: "blaxel", image: "blaxel/xfce-vnc:latest", isDesktop: true, activity: .ready, createdAt: nil, label: nil)
    }

    func testTreeShowsThisMacByDefaultAndCloudOnlyStaysOneFlipAway() {
        XCTAssertTrue(CloudTreeNodeBuilder.includesLocalMachine, "every machine — this Mac included — shows the same shape")
        let local = UUID()
        let snapshot = SurfaceCatalogSnapshot(
            machines: [info(.local), info(.cloud("vivid-newt"))],
            resources: [terminal(.local, "AAA"), terminal(.cloud("vivid-newt"), "term_1")],
            projections: [SurfaceProjection(resource: SurfaceResourceID(machine: .local, kind: .terminal, key: "AAA"), workspaceID: local, panelID: UUID())]
        )
        let workspaces = [CloudTreeLocalWorkspace(id: local, title: "cmux90", isSelected: true)]
        let byDefault = CloudTreeNodeBuilder.flattened(CloudTreeNodeBuilder.nodes(machines: [machine("vivid-newt")], snapshot: snapshot, localWorkspaces: workspaces))
        XCTAssertEqual(byDefault.first?.id, "machine:local")
        XCTAssertTrue(byDefault.contains { $0.id == "resource:vivid-newt/terminal/term_1" })

        let cloudOnly = CloudTreeNodeBuilder.flattened(CloudTreeNodeBuilder.nodes(machines: [machine("vivid-newt")], snapshot: snapshot, localWorkspaces: workspaces, includeLocalMachine: false))
        XCTAssertEqual(cloudOnly.first?.id, "machine:vivid-newt")
        XCTAssertFalse(cloudOnly.contains { $0.machine.isLocal }, "no This Mac rows when the tree is cloud-only")
    }

    func testContentChangesKeepTheStructureSignature() {
        let snapshot = SurfaceCatalogSnapshot(machines: [info(.cloud("m"))], resources: [terminal(.cloud("m"), "term_1", title: "vim")], projections: [])
        let before = CloudTreeNodeBuilder.nodes(machines: [machine("m")], snapshot: snapshot, localWorkspaces: [])
        var retitled = snapshot
        retitled.resources[0].title = "cargo test"
        retitled.projections = [SurfaceProjection(resource: retitled.resources[0].id, workspaceID: UUID(), panelID: UUID())]
        let after = CloudTreeNodeBuilder.nodes(machines: [machine("m")], snapshot: retitled, localWorkspaces: [])
        XCTAssertEqual(CloudTreeNodeBuilder.structureSignature(before), CloudTreeNodeBuilder.structureSignature(after), "a title/open-marker change is content, not structure")
        XCTAssertNotEqual(CloudTreeNodeBuilder.contentSignature(before), CloudTreeNodeBuilder.contentSignature(after))

        var grown = retitled
        grown.resources.append(terminal(.cloud("m"), "term_2"))
        let bigger = CloudTreeNodeBuilder.nodes(machines: [machine("m")], snapshot: grown, localWorkspaces: [])
        XCTAssertNotEqual(CloudTreeNodeBuilder.structureSignature(before), CloudTreeNodeBuilder.structureSignature(bigger), "a new row is structure")
    }

    func testAdoptCopiesContentIntoExistingNodes() {
        let snapshot = SurfaceCatalogSnapshot(machines: [info(.cloud("m"))], resources: [terminal(.cloud("m"), "term_1", title: "vim")], projections: [])
        let existing = CloudTreeNodeBuilder.nodes(machines: [machine("m")], snapshot: snapshot, localWorkspaces: [])
        var retitled = snapshot
        retitled.resources[0].title = "make"
        let replacement = CloudTreeNodeBuilder.nodes(machines: [machine("m")], snapshot: retitled, localWorkspaces: [])
        for (node, other) in zip(existing, replacement) { node.adopt(from: other) }
        let terminalRow = CloudTreeNodeBuilder.flattened(existing).first { $0.id == "resource:m/terminal/term_1" }
        if case .terminal(let row)? = terminalRow?.kind { XCTAssertEqual(row.resource.title, "make") } else { XCTFail("terminal row missing") }
        XCTAssertEqual(CloudTreeNodeBuilder.contentSignature(existing), CloudTreeNodeBuilder.contentSignature(replacement))
    }
}

/// Regression: a signed-in account with no cloud machines rendered a blank
/// panel instead of the empty state, because the panel judged emptiness from
/// the raw catalog (whose This Mac entry counted as a row) while the
/// cloud-only tree drew nothing. The emptiness decision must match what
/// `nodes` actually renders.
@Suite struct CloudTreeEmptyDecisionTests {
    private func info(_ machine: SurfaceMachineID) -> SurfaceMachineInfo {
        SurfaceMachineInfo(id: machine, name: machine.rawValue, status: "running", image: "blaxel/xfce-vnc:latest", hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: machine.isLocal ? .notApplicable : .connected, linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil)
    }

    private func terminal(_ machine: SurfaceMachineID, _ key: String) -> SurfaceResource {
        SurfaceResource(id: SurfaceResourceID(machine: machine, kind: .terminal, key: key), title: "shell", detail: "/root", lifecycle: .running, agent: nil, remoteWorkspace: SurfaceRemoteWorkspace(id: "ws_0", name: "0", index: 0, focused: true), port: nil, url: nil)
    }

    private func machine(_ id: String) -> MachineSnapshot {
        MachineSnapshot(id: id, provider: "blaxel", image: "blaxel/xfce-vnc:latest", isDesktop: true, activity: .ready, createdAt: nil, label: nil)
    }

    @Test func emptyDecisionMatchesWhatTheTreeRenders() {
        let localOnly = SurfaceCatalogSnapshot(machines: [info(.local)], resources: [terminal(.local, "AAA")], projections: [])
        #expect(
            CloudTreeNodeBuilder.nodes(machines: [], snapshot: localOnly, localWorkspaces: []).isEmpty,
            "precondition: the cloud-only tree renders nothing for a local-only catalog"
        )
        #expect(
            CloudTreeNodeBuilder.isEmpty(machines: [], snapshot: localOnly),
            "no cloud machines anywhere must show the empty state, even with This Mac in the catalog"
        )
        #expect(
            !CloudTreeNodeBuilder.isEmpty(machines: [], snapshot: localOnly, includeLocalMachine: true),
            "once the tree shows This Mac again, the local entry is a row"
        )

        #expect(
            !CloudTreeNodeBuilder.isEmpty(machines: [machine("vivid-newt")], snapshot: .empty),
            "a fleet machine is a row before the catalog hears about it"
        )
        let catalogOnly = SurfaceCatalogSnapshot(machines: [info(.cloud("quiet-owl"))], resources: [], projections: [])
        #expect(
            !CloudTreeNodeBuilder.isEmpty(machines: [], snapshot: catalogOnly),
            "a catalog-known cloud machine gets a placeholder row even while the fleet list lags"
        )
    }
}

/// Pins the single-line machine row's inline fact: Locked wins, then the live
/// CPU/Mem/Disk reading (when the style shows stats), else nothing.
@Suite("Cloud tree machine inline fact")
struct CloudTreeMachineInlineFactTests {
    private func snapshot(stats: VMStats?) -> MachineSnapshot {
        var machine = MachineSnapshotBuilder.snapshot(from: VMSummary(
            id: "troll", provider: "blaxel", status: "running", image: "sandbox/cmux-devbox:latest", createdAt: 0, base: nil
        ))
        machine.stats = stats
        return machine
    }

    @Test("An awake reading renders inline in the default single-line style")
    func awakeReadingRendersInline() {
        let stats = VMStats(
            state: .awake, sampledAt: Date(timeIntervalSince1970: 0), cpus: 2, cpuPercent: 9.4,
            loadAverage1m: nil, memoryTotalMb: 3891, memoryUsedMb: 3481, diskTotalMb: 3174, diskUsedMb: 2867
        )
        let fact = CloudTreeMachineRowContent.inlineFact(snapshot(stats: stats), style: .compact)
        #expect(fact?.contains("CPU 9%") == true)
        #expect(fact?.contains("3.4/3.8") == true)
    }

    @Test("No reading yet means no inline fact")
    func missingStatsShowsNothing() {
        #expect(CloudTreeMachineRowContent.inlineFact(snapshot(stats: nil), style: .compact) == nil)
    }
}

/// Pins the mapping from Cloud VM list failures to the machines pane's empty
/// state. A server-rejected session (401) must route to re-auth and a plan
/// gate (402) to the Pro upsell — neither may fall back to the retry-first
/// "Cloud is unreachable" copy that misled the nightly's 401 storm.
@Suite("Cloud machines list problem classification")
struct MachinesPanelListProblemTests {
    @Test("A server-rejected session (401) routes to a fresh sign-in")
    func rejectedSessionRoutesToReauth() {
        #expect(
            MachinesPanelViewModel.classifyListFailure(
                .httpStatus(401, #"{"error":"unauthorized"}"#)
            ) == .sessionRejected
        )
    }

    @Test("A plan gate (402) routes to the Pro upsell")
    func planGateRoutesToPro() {
        #expect(
            MachinesPanelViewModel.classifyListFailure(
                .httpStatus(402, #"{"error":"vm_requires_pro"}"#)
            ) == .requiresPro
        )
    }

    @Test("Transient-shaped failures keep the retry-first unreachable state")
    func transientFailuresStayUnreachable() {
        #expect(
            MachinesPanelViewModel.classifyListFailure(.httpStatus(503, "{}")) == .unreachable
        )
        #expect(
            MachinesPanelViewModel.classifyListFailure(
                .backendUnreachable(url: "https://cmux.com", detail: "offline")
            ) == .unreachable
        )
        #expect(
            MachinesPanelViewModel.classifyListFailure(.sessionRefreshFailed) == .unreachable
        )
        #expect(
            MachinesPanelViewModel.classifyListFailure(.malformedResponse("bad")) == .unreachable
        )
    }

    /// No "detached" pill anywhere (austin, 2026-08-31): a pool terminal with no
    /// view is just a row, one view is the normal state, and only several views
    /// earn a badge (a multiplier).
    func testPoolRowBadgeOnlyReadsAsMultiplier() {
        XCTAssertNil(CloudTreeTerminalRowContent.multiplierBadge(nil), "pointer rows and local terminals carry no badge")
        XCTAssertNil(CloudTreeTerminalRowContent.multiplierBadge(0), "zero views is not called out")
        XCTAssertNil(CloudTreeTerminalRowContent.multiplierBadge(1), "one view is the normal state")
        XCTAssertEqual(CloudTreeTerminalRowContent.multiplierBadge(2), 2)
        XCTAssertEqual(CloudTreeTerminalRowContent.multiplierBadge(5), 5)
    }
}

@Suite("Cloud machines paid-plan classification")
struct MachinesPanelPaidPlanTests {
    @Test("Only plans the backend accepts for provisioning are paid", arguments: [
        ("pro", true), ("TEAM", true), ("founders", true), (" Pro\n", true),
        ("free", false), ("", false), ("unknown", false), ("enterprise-unknown", false),
    ])
    func onlyProvisioningPlansArePaid(planId: String, expected: Bool) {
        #expect(MachinePlanSnapshot.isPaidPlanID(planId) == expected)
    }

    @Test("A plan snapshot and the shared classifier agree")
    func planSnapshotUsesSharedClassifier() {
        let paid = MachineSnapshotBuilder.planSnapshot(
            activeCount: 0,
            limits: VMPlanLimits(maxActiveVms: 5, planId: "founders", freeAccessWindowDays: 0)
        )
        #expect(paid?.isPaidPlan == true)
        let unknown = MachineSnapshotBuilder.planSnapshot(
            activeCount: 0,
            limits: VMPlanLimits(maxActiveVms: 5, planId: "mystery", freeAccessWindowDays: 0)
        )
        #expect(unknown?.isPaidPlan == false)
    }

    @Test("vm_requires_pro without a server action still names the upgrade path")
    func requiresProErrorIncludesUpgradePathWhenServerOmitsAction() {
        let error = VMClientError.httpStatus(402, #"{"error":"vm_requires_pro"}"#)
        #expect(error.description.contains("https://cmux.com/pricing"))
        #expect(error.description.contains("Upgrade to cmux Pro"))
    }
}
