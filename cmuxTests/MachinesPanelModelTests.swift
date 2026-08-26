import Foundation
import Bonsplit
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

    // MARK: - Cloud tree

    private func treeMachine(
        id: String,
        linkState: CloudTreeLinkState = .connected,
        desktop: Bool = true,
        workspaces: [CloudTreeWorkspace] = [],
        ports: [CloudTreePort] = []
    ) -> CloudTreeMachine {
        CloudTreeMachine(
            id: id,
            status: linkState == .asleep ? "standby" : "running",
            image: desktop ? "blaxel/xfce-vnc:latest" : "blaxel/base-image:latest",
            desktop: desktop,
            memoryMb: 24_576,
            diskMb: 16_384,
            linkState: linkState,
            linkError: linkState == .error ? "boom" : nil,
            workspaces: workspaces,
            ports: ports
        )
    }

    private func machineSnapshot(id: String, image: String = "blaxel/xfce-vnc:latest") -> MachineSnapshot {
        MachineSnapshotBuilder.snapshot(from: VMSummary(
            id: id, provider: "blaxel", status: "running", image: image, createdAt: 0, base: nil
        ))
    }

    func testCloudTreeOrdersMachineWorkspacesTerminalsDesktopPorts() {
        let terminal = CloudTreeTerminal(id: "term_1", title: "cargo test", cwd: "/root/app", lifecycle: .running, agentState: "running", agentSource: "claude", openSurfaceID: nil)
        let idle = CloudTreeTerminal(id: "term_2", title: "zsh", cwd: nil, lifecycle: .exited, agentState: nil, agentSource: nil, openSurfaceID: "surface:9")
        let tree = CloudTreeSnapshot(machines: [
            treeMachine(
                id: "vivid-newt",
                workspaces: [CloudTreeWorkspace(id: "ws_main", name: "main", focused: true, terminals: [terminal, idle])],
                ports: [CloudTreePort(port: 3000, label: "http")]
            ),
        ])
        let nodes = CloudTreeNodeBuilder.nodes(machines: [machineSnapshot(id: "vivid-newt")], tree: tree)
        let ids = CloudTreeNodeBuilder.flattened(nodes).map(\.id)
        XCTAssertEqual(ids, [
            "machine:vivid-newt",
            "machine:vivid-newt/workspaces",
            "machine:vivid-newt/ws/ws_main",
            "machine:vivid-newt/term/term_1",
            "machine:vivid-newt/term/term_2",
            "machine:vivid-newt/desktop",
            "machine:vivid-newt/ports",
            "machine:vivid-newt/port/3000",
        ])
        XCTAssertEqual(nodes[0].children.count, 3)
        XCTAssertTrue(nodes[0].isExpandable)
        // Every leaf that can be dragged names a daemon-side resource, never a VM alone.
        XCTAssertEqual(
            CloudTreeNodeBuilder.flattened(nodes).compactMap(\.dragItem),
            [
                .terminal(machineID: "vivid-newt", terminalID: "term_1", title: "cargo test"),
                .terminal(machineID: "vivid-newt", terminalID: "term_2", title: "zsh"),
                .desktop(machineID: "vivid-newt"),
                .port(machineID: "vivid-newt", port: 3000),
            ]
        )
    }

    func testCloudTreeSleepingMachineShowsSinglePlaceholder() {
        let tree = CloudTreeSnapshot(machines: [treeMachine(id: "quiet-owl", linkState: .asleep, desktop: false)])
        let nodes = CloudTreeNodeBuilder.nodes(machines: [machineSnapshot(id: "quiet-owl", image: "blaxel/base-image:latest")], tree: tree)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].children.count, 1)
        guard case .placeholder(let machineID, let placeholder) = nodes[0].children[0].kind else {
            return XCTFail("expected a placeholder row, got \(nodes[0].children[0].kind)")
        }
        XCTAssertEqual(machineID, "quiet-owl")
        XCTAssertEqual(placeholder.style, .dimmed)
        XCTAssertNil(nodes[0].children[0].dragItem)
    }

    func testCloudTreeLinkErrorAndMissingSnapshot() {
        let tree = CloudTreeSnapshot(machines: [treeMachine(id: "broken-elk", linkState: .error, desktop: false)])
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [machineSnapshot(id: "broken-elk"), machineSnapshot(id: "unknown-yak")],
            tree: tree
        )
        guard case .placeholder(_, let placeholder) = nodes[0].children[0].kind else {
            return XCTFail("expected an error row")
        }
        XCTAssertEqual(placeholder.style, .error)
        XCTAssertEqual(placeholder.text, "boom")
        // A machine the service has not described yet is a plain, non-expandable row.
        XCTAssertFalse(nodes[1].isExpandable)
        XCTAssertNil(CloudTreeNodeBuilder.nodes(machines: [machineSnapshot(id: "a")], tree: nil)[0].children.first)
    }

    func testCloudTreeDragItemRoundTripsThroughThePasteboardRecord() throws {
        let items: [CloudTreeDragItem] = [
            .terminal(machineID: "vivid-newt", terminalID: "term_1", title: "cargo test"),
            .desktop(machineID: "vivid-newt"),
            .port(machineID: "vivid-newt", port: 6901),
        ]
        for item in items {
            let record = CloudTreeDragPasteboardRecord(dragID: UUID(), item: item)
            let data = try JSONEncoder().encode(record)
            XCTAssertEqual(try JSONDecoder().decode(CloudTreeDragPasteboardRecord.self, from: data), record)
        }
    }

    func testCloudTreeSnapshotDecodesSnakeCaseKeys() throws {
        let json = """
        {"machines":[{"id":"vivid-newt","status":"running","image":"blaxel/xfce-vnc:latest","desktop":true,
          "memory_mb":24576,"disk_mb":16384,"link_state":"connected","workspaces":[{"id":"ws_1","name":"main","focused":true,
          "terminals":[{"id":"term_1","title":"zsh","cwd":"/root","lifecycle":"running","agent_state":"idle","agent_source":"codex","open_surface_id":"surface:3"}]}],
          "ports":[{"port":8080,"label":"http"}]}]}
        """
        let snapshot = try JSONDecoder().decode(CloudTreeSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.machines[0].linkState, .connected)
        XCTAssertEqual(snapshot.machines[0].workspaces[0].terminals[0].openSurfaceID, "surface:3")
        XCTAssertEqual(snapshot.machines[0].workspaces[0].terminals[0].agentSource, "codex")
        XCTAssertEqual(snapshot.machines[0].ports[0].label, "http")
        XCTAssertEqual(CloudTreeTerminalRowContent.abbreviated("/root/app"), "~/app")
    }

    @MainActor
    func testCloudTreeExpansionStoreDefaultsToExpandedAndPersistsMachineCollapse() {
        let defaults = UserDefaults(suiteName: "MachinesPanelModelTests.\(UUID().uuidString)")!
        let store = CloudTreeExpansionStore(defaults: defaults)
        let machineNode = CloudTreeNodeBuilder.nodes(
            machines: [machineSnapshot(id: "vivid-newt")],
            tree: CloudTreeSnapshot(machines: [treeMachine(id: "vivid-newt")])
        )[0]
        let group = machineNode.children[0]
        XCTAssertTrue(store.isExpanded(machineNode))
        XCTAssertTrue(store.isExpanded(group))
        store.setExpanded(false, node: machineNode)
        store.setExpanded(false, node: group)
        XCTAssertFalse(store.isExpanded(machineNode))
        XCTAssertFalse(store.isExpanded(group))
        // Machines persist; nested rows are panel-lifetime only.
        let reloaded = CloudTreeExpansionStore(defaults: defaults)
        XCTAssertFalse(reloaded.isExpanded(machineNode))
        XCTAssertTrue(reloaded.isExpanded(group))
    }

    // MARK: - Cloud tree (machines → cmux-tui workspaces → terminals)

    private static let cloudSessionSnapshotFixture: [String: Any] = [
        "workspaces": [
            ["id": "ws_main", "name": "main", "focused": true],
            ["id": "ws_api", "name": "api", "focused": false],
        ],
        "screens": [
            ["id": "screen_1", "workspace_id": "ws_main"],
            ["id": "screen_2", "workspace_id": "ws_api"],
        ],
        "panes": [
            ["id": "pane_1", "screen_id": "screen_1"],
            ["id": "pane_2", "screen_id": "screen_2"],
        ],
        "tabs": [
            ["id": "tab_1", "pane_id": "pane_1", "content_kind": "terminal", "content_id": "term_build"],
            ["id": "tab_2", "pane_id": "pane_2", "content_kind": "terminal", "content_id": "term_shell"],
            ["id": "tab_3", "pane_id": "pane_1", "content_kind": "browser", "content_id": "browser_1"],
        ],
        "terminals": [
            ["id": "term_build", "tab_id": "tab_1", "tab_ids": ["tab_1"], "title": "cargo test", "cwd": "/root/work/app", "lifecycle": "running", "running": true],
            ["id": "term_shell", "tab_id": "tab_2", "tab_ids": ["tab_2"], "title": "", "lifecycle": "exited", "running": false],
            ["id": "term_orphan", "tab_id": "tab_missing", "tab_ids": [], "title": "orphan", "running": true],
        ],
        "agents": [
            ["id": "agent_1", "terminal_id": "term_build", "state": "working", "source": "claude"],
        ],
    ]

    func testCloudTreeSnapshotParserAttributesTerminalsToWorkspaces() {
        let workspaces = CloudTreeSnapshotParser.workspaces(fromSnapshot: Self.cloudSessionSnapshotFixture)
        XCTAssertEqual(workspaces.map(\.id), ["ws_main", "ws_api"])
        XCTAssertEqual(workspaces[0].name, "main")
        XCTAssertTrue(workspaces[0].focused)
        // Terminals reach their workspace through tab → pane → screen; an orphan lands in the first.
        XCTAssertEqual(workspaces[0].terminals.map(\.id), ["term_build", "term_orphan"])
        XCTAssertEqual(workspaces[1].terminals.map(\.id), ["term_shell"])

        let build = workspaces[0].terminals[0]
        XCTAssertEqual(build.title, "cargo test")
        XCTAssertEqual(build.cwd, "/root/work/app")
        XCTAssertEqual(build.lifecycle, .running)
        XCTAssertEqual(build.agentState, "working")
        XCTAssertEqual(build.agentSource, "claude")
        XCTAssertNil(build.openSurfaceID)

        let shell = workspaces[1].terminals[0]
        XCTAssertEqual(shell.title, "", "an untitled terminal without cwd stays untitled so the row shows the localized fallback, not the raw id")
        XCTAssertEqual(shell.lifecycle, .exited)
        XCTAssertNil(shell.agentState)

        // No lifecycle key: `running` decides.
        XCTAssertEqual(workspaces[0].terminals[1].lifecycle, .running)
    }

    func testCloudTreeSnapshotParserHandlesEmptyAndMalformedSnapshots() {
        XCTAssertEqual(CloudTreeSnapshotParser.workspaces(fromSnapshot: [:]), [])
        XCTAssertEqual(CloudTreeSnapshotParser.workspaces(fromSnapshot: ["workspaces": [["name": "no id"]]]), [])
        XCTAssertNil(CloudTreeSnapshotParser.terminal(fromSnapshotEntry: ["title": "no id"]))
    }

    func testCloudTreeSnapshotParserReadsRunResultsAndLinkLines() {
        let wrapped: [String: Any] = [
            "value": ["kind": "terminal", "workspace_id": "ws_main", "screen_id": "screen_1", "pane_id": "pane_1", "tab_id": "tab_9", "terminal_id": "term_new"],
            "generation": "g1", "revision": "42", "replayed": false,
        ]
        let created = CloudTreeSnapshotParser.createdTerminal(fromRunResult: wrapped)
        XCTAssertEqual(created?.terminalID, "term_new")
        XCTAssertEqual(created?.workspaceID, "ws_main")
        XCTAssertEqual(CloudTreeSnapshotParser.createdTerminal(fromRunResult: ["terminal_id": "term_bare"])?.terminalID, "term_bare")
        XCTAssertNil(CloudTreeSnapshotParser.createdTerminal(fromRunResult: ["value": ["kind": "terminal"]]))

        XCTAssertEqual(
            CloudTreeSnapshotParser.localSocket(fromLinkLine: #"{"event":"connection-snapshot","local_socket":"/tmp/x/mux.sock","connection":{}}"#),
            "/tmp/x/mux.sock"
        )
        XCTAssertNil(CloudTreeSnapshotParser.localSocket(fromLinkLine: #"{"event":"other","local_socket":"/tmp/x"}"#))
        XCTAssertNil(CloudTreeSnapshotParser.localSocket(fromLinkLine: "not json"))
    }

    func testCloudTreeSnapshotParserListsListeningPorts() {
        let ss = """
        State   Recv-Q  Send-Q  Local Address:Port  Peer Address:Port Process
        LISTEN  0       4096    0.0.0.0:3000        0.0.0.0:*
        LISTEN  0       128     [::]:1337           [::]:*
        LISTEN  0       128     127.0.0.1:5901      0.0.0.0:*
        LISTEN  0       128     0.0.0.0:3000        0.0.0.0:*
        """
        let ports = CloudTreeSnapshotParser.listeningPorts(fromSocketListing: ss).map(\.port)
        XCTAssertEqual(ports, [1337, 3000, 5901])
        XCTAssertTrue(CloudTreeSnapshotParser.internalPorts.contains(1337))
        XCTAssertTrue(CloudTreeSnapshotParser.internalPorts.contains(5901))
        XCTAssertTrue(CloudTreeSnapshotParser.machineHasDesktop(image: "blaxel/xfce-vnc:latest"))
        XCTAssertFalse(CloudTreeSnapshotParser.machineHasDesktop(image: "blaxel/base-image:latest"))
    }

    func testCloudTuiCommandLineBuildsExactArgv() {
        XCTAssertEqual(
            CloudTuiCommandLine.linkArguments(route: "wss://m.vm.cmux.sh/v1/link?t=1", deviceName: "cmux-mac", stateDir: "/s", inviteFilePath: "/i"),
            ["remote", "connect", "wss://m.vm.cmux.sh/v1/link?t=1", "--device-name", "cmux-mac", "--state-dir", "/s", "--headless", "--json", "--invite-file", "/i"]
        )
        XCTAssertEqual(
            CloudTuiCommandLine.linkArguments(route: "r", deviceName: "d", stateDir: "/s", inviteFilePath: nil),
            ["remote", "connect", "r", "--device-name", "d", "--state-dir", "/s", "--headless", "--json"]
        )
        XCTAssertEqual(CloudTuiCommandLine.snapshotArguments(socketPath: "/k.sock"), ["--socket", "/k.sock", "--json", "session", "current", "snapshot"])
        XCTAssertEqual(CloudTuiCommandLine.eventsArguments(socketPath: "/k.sock"), ["--socket", "/k.sock", "--jsonl", "session", "current", "events"])
        XCTAssertEqual(
            CloudTuiCommandLine.runArguments(socketPath: "/k.sock", workspaceID: "ws_main", command: ["claude", "-p", "fix it"]),
            ["--socket", "/k.sock", "--json", "workspace", "ws_main", "run", "--", "claude", "-p", "fix it"]
        )
        XCTAssertEqual(CloudTuiCommandLine.attachArguments(socketPath: "/k.sock", terminalID: "term_1"), ["--socket", "/k.sock", "attach", "--terminal", "term_1"])
        XCTAssertEqual(
            CloudTuiCommandLine.attachShellCommand(clientPath: "/Applications/cmux DEV.app/Contents/Resources/bin/cmux-tui", socketPath: "/k.sock", terminalID: "term_1"),
            "'/Applications/cmux DEV.app/Contents/Resources/bin/cmux-tui' --socket /k.sock attach --terminal term_1"
        )
        XCTAssertEqual(CloudTuiCommandLine.commandStartingIn(cwd: nil, command: ["bash", "-l"]), ["bash", "-l"])
        XCTAssertEqual(
            CloudTuiCommandLine.commandStartingIn(cwd: "/root/work/my app", command: ["codex", "exec", "it's"]),
            ["sh", "-lc", "cd '/root/work/my app' && exec codex exec 'it'\\''s'"]
        )
    }

    func testCloudTuiClientPathsMirrorTheCLI() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-cloud-paths-\(UUID().uuidString)")
        let paths = CloudTuiClientPaths(home: home)
        XCTAssertEqual(paths.stateDir.path, home.appendingPathComponent(".cmuxterm/cmux-tui-client").path)
        XCTAssertEqual(paths.devicesStoreURL.path, home.appendingPathComponent(".cmuxterm/vm-tui-devices.json").path)
        XCTAssertNil(paths.deviceFingerprint(for: "vivid-newt"))
        paths.saveDeviceFingerprint("fp-1", for: "vivid-newt")
        XCTAssertEqual(paths.deviceFingerprint(for: "vivid-newt"), "fp-1")
        // Same JSON shape the CLI's `saveVMTuiDevice` writes.
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.devicesStoreURL)) as? [String: [String: Any]]
        XCTAssertEqual(raw?["vivid-newt"]?["deviceFingerprint"] as? String, "fp-1")
        XCTAssertNotNil(raw?["vivid-newt"]?["updatedAtUnix"])
        XCTAssertTrue(CloudTuiClientPaths.deviceName(hostName: "Austin's MacBook.local").hasPrefix("cmux-Austin-s-MacBook"))
        try? FileManager.default.removeItem(at: home)
    }

    func testCloudTreeMachineEncodesSnakeCaseWireKeys() throws {
        let machine = CloudTreeMachine(
            id: "vivid-newt", status: "running", image: "blaxel/xfce-vnc:latest", desktop: true,
            memoryMb: 24_064, diskMb: 16_384, linkState: .connected, linkError: nil,
            workspaces: [CloudTreeWorkspace(id: "ws_1", name: "main", focused: true, terminals: [
                CloudTreeTerminal(id: "term_1", title: "zsh", cwd: "/root", lifecycle: .running, agentState: nil, agentSource: nil, openSurfaceID: "ABC"),
            ])],
            ports: [CloudTreePort(port: 3000, label: nil)]
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(CloudTreeSnapshot(machines: [machine]))) as? [String: Any])
        let encoded = try XCTUnwrap((object["machines"] as? [[String: Any]])?.first)
        XCTAssertEqual(encoded["memory_mb"] as? Int, 24_064)
        XCTAssertEqual(encoded["disk_mb"] as? Int, 16_384)
        XCTAssertEqual(encoded["link_state"] as? String, "connected")
        let terminal = try XCTUnwrap(((encoded["workspaces"] as? [[String: Any]])?.first?["terminals"] as? [[String: Any]])?.first)
        XCTAssertEqual(terminal["open_surface_id"] as? String, "ABC")
        XCTAssertEqual(terminal["lifecycle"] as? String, "running")
    }

    // MARK: - Cloud tree drop target

    func testCloudTreeDropTargetMapsEverySplitSideAndInserts() {
        let pane = PaneID()
        let surface = UUID()
        func target(_ destination: BonsplitController.ExternalTabDropRequest.Destination) -> CloudTreeOpenTarget {
            CloudTreeOpenTarget.dropTarget(destination: destination, surfaceID: surface)
        }
        // Left/top are the "insert first" sides of a horizontal/vertical split — the
        // same reading Workspace.handleSessionDrop gives a Vault drop.
        XCTAssertEqual(target(.split(targetPane: pane, orientation: .horizontal, insertFirst: true)).direction, .left)
        XCTAssertEqual(target(.split(targetPane: pane, orientation: .horizontal, insertFirst: false)).direction, .right)
        XCTAssertEqual(target(.split(targetPane: pane, orientation: .vertical, insertFirst: true)).direction, .up)
        XCTAssertEqual(target(.split(targetPane: pane, orientation: .vertical, insertFirst: false)).direction, .down)
        let split = target(.split(targetPane: pane, orientation: .horizontal, insertFirst: true))
        XCTAssertEqual(split.paneID, pane.id.uuidString)
        XCTAssertEqual(split.surfaceID, surface.uuidString)
        XCTAssertNil(split.tabIndex)
        XCTAssertEqual(split.placement, .split)
        XCTAssertFalse(split.isEmpty)

        let insert = target(.insert(targetPane: pane, targetIndex: 2))
        XCTAssertNil(insert.direction)
        XCTAssertEqual(insert.tabIndex, 2)
        XCTAssertEqual(insert.paneID, pane.id.uuidString)
        XCTAssertEqual(insert.placement, .tab)

        XCTAssertTrue(CloudTreeOpenTarget().isEmpty)
        XCTAssertEqual(CloudTreeOpenTarget().placement, .tab)
    }

    func testCloudTreeDropTargetEncodesSocketParamNames() throws {
        let target = CloudTreeOpenTarget(paneID: "p", surfaceID: "s", direction: .up, tabIndex: 1)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(target)) as? [String: Any]
        XCTAssertEqual(object?["pane_id"] as? String, "p")
        XCTAssertEqual(object?["surface_id"] as? String, "s")
        XCTAssertEqual(object?["direction"] as? String, "up")
        XCTAssertEqual(object?["tab_index"] as? Int, 1)
    }
}
