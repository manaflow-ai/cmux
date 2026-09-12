import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The Cloud tree stack is shared by the Cloud tab and the Devices tab through
/// one switch, `CloudTreeMachineSource`. These pin the three shapes: the Cloud
/// tab ignores device machines (byte-for-byte what it was), the Devices tab
/// lists only devices with the cloud machine's child shape, and the merged
/// shape appends one Devices section after the fleet.
@Suite("Devices: Cloud-tree builder with device machines")
struct DevicesCloudTreeBuilderTests {
    private let studio = SurfaceDeviceInstanceID(deviceID: "22222222-2222-2222-2222-222222222222", tag: "default")
    private let laptop = SurfaceDeviceInstanceID(deviceID: "33333333-3333-3333-3333-333333333333", tag: "issue-8001")

    @MainActor
    @Test("A reveal waits for its device row, expands it once, and accepts a later Open request")
    func revealWaitsForDeviceRow() throws {
        let suiteName = "DevicesCloudTreeReveal-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = makeCoordinator(defaults: defaults)
        let container = CloudTreeContainerView(coordinator: coordinator)
        let outline = try #require(coordinator.outlineView)
        let request = CloudTreeRevealRequest.machine(.device(studio))
        coordinator.reveal(request)

        let snapshot = SurfaceCatalogSnapshot(
            machines: [info(studio, name: "Studio", online: true, linkState: .connected)],
            resources: [], projections: []
        )
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: snapshot, localWorkspaces: [], includeLocalMachine: false, source: .cloudWithDevicesSection
        )
        let section = try #require(nodes.first)
        let device = try #require(section.children.first)
        coordinator.apply(nodes: nodes)
        outline.collapseItem(device)
        outline.collapseItem(section)
        coordinator.reveal(request)
        #expect(outline.isItemExpanded(section))
        #expect(outline.isItemExpanded(device))
        #expect(outline.selectedRow == outline.row(forItem: device))

        outline.collapseItem(device)
        outline.deselectAll(nil)
        coordinator.reveal(request)
        #expect(!outline.isItemExpanded(device))
        #expect(outline.selectedRow == -1)

        coordinator.reveal(.machine(.device(studio)))
        #expect(outline.isItemExpanded(device))
        #expect(outline.selectedRow == outline.row(forItem: device))
        _ = container
    }

    @MainActor
    private func makeCoordinator(defaults: UserDefaults) -> CloudTreeOutlineView.Coordinator {
        return CloudTreeOutlineView.Coordinator(
            machineActions: MachineRowActions(
                setupVPN: { _ in },
                openShell: { _ in }, openDesktop: { _ in }, runCommand: { _, _ in },
                confirmDelete: { _ in }, promptRename: { _, _ in }, promptUpgrade: {}
            ),
            nodeActions: CloudTreeNodeActions(
                project: { _, _, _ in }, projectRemoteView: { _, _, _, _ in },
                projectInLocalWorkspace: { _, _ in }, projectRemoteViewInLocalWorkspace: { _, _, _ in },
                newTerminal: { _, _ in }, openGroup: { _, _, _, _ in }, openGroupAsWorkspace: { _, _, _ in },
                newWorkspace: { _ in }, closeTerminal: { _ in }, closeWorkspace: { _, _ in },
                renameWorkspace: { _, _ in }, renameTerminal: { _, _ in },
                selectLocalWorkspace: { _ in }, copyToPasteboard: { _ in }, copyPortLink: { _ in }, refresh: {}
            ),
            expansionStore: CloudTreeExpansionStore(defaults: defaults),
            tabDragTransferRegistry: { nil }
        )
    }

    @MainActor
    @Test("An online device row with workspace or terminal counts is taller than a two-line row")
    func deviceRowHeightGrowsWithResourceSummary() throws {
        let suite = "DeviceRowHeight-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = makeCoordinator(defaults: defaults)
        let container = CloudTreeContainerView(coordinator: coordinator)
        let outline = try #require(coordinator.outlineView)
        func node(linkState: SurfaceLinkState, workspaces: Int, terminals: Int) -> CloudTreeNode {
            let row = CloudTreeDeviceRow(
                instance: studio, name: "Studio", presence: nil,
                linkState: linkState, linkError: nil, workspaceCount: workspaces, terminalCount: terminals
            )
            return CloudTreeNode(id: CloudTreeNodeBuilder.nodeID(machine: row.machine), kind: .device(row))
        }
        let idle = node(linkState: .connected, workspaces: 0, terminals: 0)
        let busy = node(linkState: .connected, workspaces: 2, terminals: 3)
        let offline = node(linkState: .offline, workspaces: 2, terminals: 3)
        coordinator.apply(nodes: [idle, busy, offline])
        let idleHeight = coordinator.outlineView(outline, heightOfRowByItem: idle)
        let busyHeight = coordinator.outlineView(outline, heightOfRowByItem: busy)
        let offlineHeight = coordinator.outlineView(outline, heightOfRowByItem: offline)
        #expect(busyHeight > idleHeight, "the third resource line needs room instead of clipping")
        #expect(offlineHeight == idleHeight, "offline Macs hide their counts and keep the two-line row")
        _ = container
    }

    @MainActor
    @Test("Hover and menu creation actions require a trusted connected device")
    func deviceCreationActionsRequireConnection() throws {
        let suite = "DeviceCreationActions-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = makeCoordinator(defaults: defaults)
        let container = CloudTreeContainerView(coordinator: coordinator)
        let newTerminal = String(localized: "cloudTree.menu.newTerminal", defaultValue: "New Terminal")
        let newWorkspace = String(localized: "cloudTree.menu.newWorkspace", defaultValue: "New Workspace")
        let cases: [(SurfaceLinkState, SurfaceDevicePresence.AccountTrust?, Bool)] = [
            (.unavailable, .sameAccount, false), (.connecting, .sameAccount, false),
            (.offline, .sameAccount, false), (.error, .sameAccount, false),
            (.connected, .otherAccount, false), (.connected, .unknown, false),
            (.connected, nil, false), (.connected, .sameAccount, true)
        ]
        for (state, trust, expected) in cases {
            let row = CloudTreeDeviceRow(
                instance: studio, name: "Studio",
                presence: trust.map { presence(online: true, tag: "default", trust: $0) },
                linkState: state, linkError: nil, workspaceCount: 0, terminalCount: 0
            )
            let node = CloudTreeNode(id: CloudTreeNodeBuilder.nodeID(machine: row.machine), kind: .device(row))
            coordinator.apply(nodes: [node])
            #expect(CloudTreeRowHoverButtons.hasButtons(for: node.kind) == expected)
            let menu = try #require(coordinator.contextMenu(forRow: 0))
            #expect(menu.items.contains { $0.title == newTerminal } == expected)
            #expect(menu.items.contains { $0.title == newWorkspace } == expected)
        }
        _ = container
    }

    @MainActor
    @Test("Revoked device links do not expose creation controls through cached terminal pools")
    func unavailableDeviceHidesCachedCreationActions() {
        let workspace = SurfaceRemoteWorkspace(id: "w1", name: "Work", index: 0, focused: true)
        let snapshot = SurfaceCatalogSnapshot(
            machines: [info(studio, name: "Studio", online: true, linkState: .unavailable, workspaces: [workspace])],
            resources: [terminal("t1", on: .device(studio), in: workspace, title: "zsh")], projections: []
        )
        let nodes = CloudTreeNodeBuilder.nodes(machines: [], snapshot: snapshot, localWorkspaces: [], source: .devices)
        #expect(CloudTreeNodeBuilder.flattened(nodes).allSatisfy { !CloudTreeRowHoverButtons.hasButtons(for: $0.kind) })
    }

    private func presence(
        online: Bool,
        tag: String,
        trust: SurfaceDevicePresence.AccountTrust = .sameAccount,
        lastSeenAt: Date? = nil
    ) -> SurfaceDevicePresence {
        SurfaceDevicePresence(state: online ? .online : .offline, lastSeenAt: lastSeenAt, tag: tag, bundleID: "com.cmuxterm.app", accountTrust: trust)
    }

    private func info(
        _ instance: SurfaceDeviceInstanceID,
        name: String,
        online: Bool,
        linkState: SurfaceLinkState,
        linkError: String? = nil,
        workspaces: [SurfaceRemoteWorkspace] = []
    ) -> SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: .device(instance), name: name, status: online ? "running" : "offline", image: nil, hasDesktop: false,
            memoryMb: nil, diskMb: nil, linkState: linkState, linkError: linkError,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil, remoteWorkspaces: workspaces,
            presence: presence(online: online, tag: instance.tag)
        )
    }

    private func cloudInfo(_ id: String) -> SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: .cloud(id), name: id, status: "running", image: "sh-1", hasDesktop: false,
            memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil, remoteWorkspaces: []
        )
    }

    private func fleetRow(_ id: String) -> MachineSnapshot {
        MachineSnapshot(id: id, provider: "freestyle", image: "sh-1", isDesktop: false, activity: .ready, createdAt: nil, label: id)
    }

    private func terminal(_ key: String, on machine: SurfaceMachineID, in workspace: SurfaceRemoteWorkspace, title: String) -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: key), title: title, detail: nil,
            lifecycle: .running, agent: nil, remoteWorkspace: workspace,
            remoteViews: [SurfaceRemoteView(tabID: key, workspace: workspace, index: 0, focused: false)],
            port: nil, url: nil
        )
    }

    @Test("The Cloud tab ignores device machines entirely")
    func cloudSourceIgnoresDevices() {
        let snapshot = SurfaceCatalogSnapshot(
            machines: [info(studio, name: "Studio", online: true, linkState: .connected)], resources: [], projections: []
        )
        let nodes = CloudTreeNodeBuilder.nodes(machines: [], snapshot: snapshot, localWorkspaces: [], includeLocalMachine: false, source: .cloud)
        #expect(nodes.isEmpty)
        #expect(CloudTreeNodeBuilder.isEmpty(machines: [], snapshot: snapshot, includeLocalMachine: false, source: .cloud))
        #expect(!CloudTreeNodeBuilder.isEmpty(machines: [], snapshot: snapshot, includeLocalMachine: false, source: .devices))
        #expect(!CloudTreeNodeBuilder.isEmpty(machines: [], snapshot: snapshot, includeLocalMachine: false, source: .cloudWithDevicesSection))
        let fleetOnly = SurfaceCatalogSnapshot(machines: [cloudInfo("brave-otter")], resources: [], projections: [])
        #expect(CloudTreeNodeBuilder.isEmpty(machines: [], snapshot: fleetOnly, includeLocalMachine: false, source: .devices))
        #expect(!CloudTreeNodeBuilder.isEmpty(machines: [], snapshot: fleetOnly, includeLocalMachine: false, source: .cloud))
    }

    @Test("The Devices tab lists only devices, online first, each with the cloud machine's child shape")
    func devicesSourceBuildsDeviceRows() throws {
        let main = SurfaceRemoteWorkspace(id: "w1", name: "api", index: 0, focused: true, detail: "/Users/me/api", unreadCount: 2, isPinned: false)
        let studioMachine = SurfaceMachineID.device(studio)
        let snapshot = SurfaceCatalogSnapshot(
            machines: [
                cloudInfo("brave-otter"),
                info(laptop, name: "Laptop", online: false, linkState: .offline),
                info(studio, name: "Studio", online: true, linkState: .connected, workspaces: [main]),
            ],
            resources: [terminal("t1", on: studioMachine, in: main, title: "zsh")],
            projections: []
        )
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [fleetRow("brave-otter")], snapshot: snapshot, localWorkspaces: [], includeLocalMachine: true, source: .devices
        )
        #expect(nodes.count == 2, "no fleet row, no This Mac")
        guard case .device(let studioRow) = nodes[0].kind else {
            Issue.record("expected the online device first, got \(nodes[0].kind)")
            return
        }
        #expect(studioRow.name == "Studio")
        #expect(studioRow.isOnline)
        #expect(studioRow.workspaceCount == 1)
        #expect(studioRow.terminalCount == 1)
        #expect(studioRow.indicator == .online)
        #expect(studioRow.machine == studioMachine)
        guard case .device(let laptopRow) = nodes[1].kind else {
            Issue.record("expected the offline device second")
            return
        }
        #expect(laptopRow.name == "Laptop")
        #expect(laptopRow.indicator == .offline)

        // Online device: Workspaces group → workspace row → terminal, then the Terminals pool; never ports.
        var sawWorkspacesGroup = false
        var sawWorkspace = false
        var sawTerminal = false
        var sawPool = false
        var sawPorts = false
        var sawDisplays = false
        for node in CloudTreeNodeBuilder.flattened(nodes[0].children) {
            switch node.kind {
            case .workspacesGroup(let machine):
                sawWorkspacesGroup = machine == studioMachine
            case .workspace(let machine, let workspace, let terminalCount, _, _):
                sawWorkspace = machine == studioMachine && workspace.id == "w1" && terminalCount == 1
            case .terminal(let row):
                sawTerminal = row.resource.id.key == "t1"
            case .terminalsPool(let machine, let count):
                sawPool = machine == studioMachine && count == 1
            case .portsGroup, .port:
                sawPorts = true
            case .displaysPool, .display:
                sawDisplays = true
            default:
                break
            }
        }
        #expect(sawWorkspacesGroup)
        #expect(sawWorkspace)
        #expect(sawTerminal)
        #expect(sawPool)
        #expect(!sawPorts, "devices have no port forwards")
        #expect(!sawDisplays, "personal devices have no Cloud display group")

        // Offline device: one dimmed placeholder, no groups.
        let offlineChildren = nodes[1].children
        #expect(offlineChildren.count == 1)
        let placeholderNode = try #require(offlineChildren.first)
        guard case .placeholder(let machine, let placeholder) = placeholderNode.kind else {
            Issue.record("expected a placeholder under the offline device, got \(placeholderNode.kind)")
            return
        }
        #expect(machine == .device(laptop))
        #expect(placeholder.style == .dimmed)
    }

    @Test("An empty My Devices section remains visible beneath the cloud fleet")
    func emptyDevicesSectionRemainsVisible() throws {
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: .empty, localWorkspaces: [],
            includeLocalMachine: false, source: .cloudWithDevicesSection
        )
        let section = try #require(nodes.first)
        guard case .devicesSection(let count) = section.kind else {
            Issue.record("Expected the My Devices section")
            return
        }
        #expect(count == 0)
        #expect(!section.children.isEmpty)
        #expect(!CloudTreeNodeBuilder.isEmpty(
            machines: [], snapshot: .empty, includeLocalMachine: false,
            source: .cloudWithDevicesSection
        ))
    }

    @Test("Merged into the Cloud tab, devices sit under one Devices section after the fleet")
    func cloudWithDevicesSection() throws {
        let snapshot = SurfaceCatalogSnapshot(
            machines: [cloudInfo("brave-otter"), info(studio, name: "Studio", online: true, linkState: .connecting)],
            resources: [], projections: []
        )
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [fleetRow("brave-otter")], snapshot: snapshot, localWorkspaces: [], includeLocalMachine: false,
            source: .cloudWithDevicesSection
        )
        #expect(nodes.count == 2)
        guard case .machine(let fleet, _) = nodes[0].kind else {
            Issue.record("expected the fleet row first, got \(nodes[0].kind)")
            return
        }
        #expect(fleet.id == "brave-otter")
        guard case .devicesSection(let count) = nodes[1].kind else {
            Issue.record("expected the Devices section last, got \(nodes[1].kind)")
            return
        }
        #expect(count == 1)
        #expect(nodes[1].id == CloudTreeNodeBuilder.devicesSectionNodeID)
        let sectionChild = try #require(nodes[1].children.first)
        guard case .device(let row) = sectionChild.kind else {
            Issue.record("expected a device row under the section")
            return
        }
        #expect(row.indicator == .connecting)
        let fleetOnly = SurfaceCatalogSnapshot(machines: [cloudInfo("brave-otter")], resources: [], projections: [])
        let emptyDevices = CloudTreeNodeBuilder.nodes(
            machines: [fleetRow("brave-otter")], snapshot: fleetOnly, localWorkspaces: [], includeLocalMachine: false,
            source: .cloudWithDevicesSection
        )
        #expect(emptyDevices.count == 2)
        let emptySection = try #require(emptyDevices.last)
        guard case .devicesSection(let emptyCount) = emptySection.kind else {
            Issue.record("expected the empty My Devices section after the fleet")
            return
        }
        #expect(emptyCount == 0)
        #expect(emptySection.children.count == 1)
        let cloudOnly = CloudTreeNodeBuilder.nodes(
            machines: [fleetRow("brave-otter")], snapshot: fleetOnly, localWorkspaces: [], includeLocalMachine: false,
            source: .cloud
        )
        #expect(cloudOnly.count == 1)
    }

    @Test("My Devices follows all fleet and catalog-only cloud machines")
    func devicesFollowEntireFleet() {
        let snapshot = SurfaceCatalogSnapshot(
            machines: [info(studio, name: "Studio", online: true, linkState: .connected), cloudInfo("catalog-only"), cloudInfo("fleet-a"), cloudInfo("fleet-b")],
            resources: [], projections: []
        )
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [fleetRow("fleet-b"), fleetRow("fleet-a")],
            snapshot: snapshot, localWorkspaces: [], includeLocalMachine: false,
            source: .cloudWithDevicesSection
        )
        #expect(nodes.map(\.id) == [
            CloudTreeNodeBuilder.nodeID(machine: .cloud("fleet-b")),
            CloudTreeNodeBuilder.nodeID(machine: .cloud("fleet-a")),
            CloudTreeNodeBuilder.nodeID(machine: .cloud("catalog-only")),
            CloudTreeNodeBuilder.devicesSectionNodeID,
        ])
    }

    @Test("Device rows fold presence and link state into one indicator and status")
    func deviceRowStatus() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func row(
            online: Bool,
            link: SurfaceLinkState,
            trust: SurfaceDevicePresence.AccountTrust = .sameAccount,
            error: String? = nil,
            seen: Date? = nil
        ) -> CloudTreeDeviceRow {
            CloudTreeDeviceRow(
                instance: studio, name: "Studio", presence: presence(online: online, tag: "default", trust: trust, lastSeenAt: seen),
                linkState: link, linkError: error, workspaceCount: 0, terminalCount: 0
            )
        }
        #expect(row(online: true, link: .connected).indicator == .online)
        #expect(row(online: true, link: .connecting).indicator == .connecting)
        #expect(row(online: true, link: .error).indicator == .attention)
        #expect(row(online: true, link: .unavailable).indicator == .attention)
        #expect(row(online: false, link: .connected).indicator == .online, "a live link wins over stale presence")
        #expect(row(online: false, link: .connecting).indicator == .connecting)
        #expect(row(online: false, link: .offline).indicator == .offline)
        let connectedWithoutPresence = CloudTreeDeviceRow(
            instance: studio, name: "Studio", presence: nil, linkState: .connected,
            linkError: nil, workspaceCount: 0, terminalCount: 0
        )
        #expect(connectedWithoutPresence.indicator == .online)
        #expect(connectedWithoutPresence.statusLabel(now: now) == String(localized: "cloudTree.device.status.online", defaultValue: "Online"))
        #expect(row(online: true, link: .connected).statusLabel(now: now) == String(localized: "cloudTree.device.status.online", defaultValue: "Online"))
        #expect(row(online: true, link: .error, error: "Handshake failed").statusLabel(now: now) == "Handshake failed")
        #expect(row(online: true, link: .unavailable, trust: .otherAccount).statusLabel(now: now) == String(localized: "cloudTree.device.status.otherAccount", defaultValue: "Another account"))
        #expect(row(online: false, link: .offline).statusLabel(now: now) == String(localized: "cloudTree.device.status.offline", defaultValue: "Offline"))
        #expect(row(online: false, link: .offline, seen: now.addingTimeInterval(-300)).statusLabel(now: now) == String(format: String(localized: "cloudTree.device.status.offlineSince", defaultValue: "Offline \u{00B7} seen %@"), String(format: String(localized: "cloudTree.device.age.minutes", defaultValue: "%dm ago"), 5)))
        #expect(row(online: false, link: .connected).statusLabel(now: now) == String(localized: "cloudTree.device.status.online", defaultValue: "Online"))
        let unknown = CloudTreeDeviceRow(
            instance: studio, name: "Studio",
            presence: SurfaceDevicePresence(state: .unknown, lastSeenAt: now.addingTimeInterval(-3_600), tag: "default", bundleID: nil, accountTrust: .sameAccount),
            linkState: .offline, linkError: nil, workspaceCount: 0, terminalCount: 0
        )
        #expect(unknown.statusLabel(now: now) == String(format: String(localized: "cloudTree.device.status.unknownSince", defaultValue: "Last seen %@"), String(format: String(localized: "cloudTree.device.age.hours", defaultValue: "%dh ago"), 1)))
        #expect(unknown.indicator == .offline)
    }

    @Test("Relative age and tag-qualified names")
    func ageAndNames() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(CloudTreeDeviceRow.relativeAge(from: now.addingTimeInterval(-10), now: now) == String(localized: "cloudTree.device.age.justNow", defaultValue: "just now"))
        #expect(CloudTreeDeviceRow.relativeAge(from: now.addingTimeInterval(-90), now: now) == String(format: String(localized: "cloudTree.device.age.minutes", defaultValue: "%dm ago"), 1))
        #expect(CloudTreeDeviceRow.relativeAge(from: now.addingTimeInterval(-7_200), now: now) == String(format: String(localized: "cloudTree.device.age.hours", defaultValue: "%dh ago"), 2))
        #expect(CloudTreeDeviceRow.relativeAge(from: now.addingTimeInterval(-47 * 3_600), now: now) == String(format: String(localized: "cloudTree.device.age.hours", defaultValue: "%dh ago"), 47))
        #expect(CloudTreeDeviceRow.relativeAge(from: now.addingTimeInterval(-3 * 86_400), now: now) == String(format: String(localized: "cloudTree.device.age.days", defaultValue: "%dd ago"), 3))
        #expect(CloudTreeDeviceRow.relativeAge(from: now.addingTimeInterval(60), now: now) == String(localized: "cloudTree.device.age.justNow", defaultValue: "just now"), "clock skew never yields a negative age")
        #expect(CloudTreeDeviceRow.displayName(baseName: "Studio", instance: studio) == "Studio")
        #expect(CloudTreeDeviceRow.displayName(baseName: "Laptop", instance: laptop) == "Laptop (issue-8001)")
        #expect(CloudTreeDeviceRow.displayName(baseName: "Laptop (issue-8001)", instance: laptop) == "Laptop (issue-8001) (issue-8001)", "a raw Mac name ending in the tag still needs its instance qualifier")
        #expect(CloudTreeDeviceRow.displayName(baseName: "  ", instance: studio) == "22222222")
    }

    @Test(
        "Connected devices sort online even when presence is stale or missing",
        arguments: [.offline, .unknown, nil] as [SurfaceDevicePresence.State?]
    )
    func orderingUsesLiveLink(state: SurfaceDevicePresence.State?) {
        let offline = info(laptop, name: "Alpha", online: false, linkState: .offline)
        var connected = info(studio, name: "Zulu", online: false, linkState: .connected)
        connected.presence = state.map {
            SurfaceDevicePresence(state: $0, lastSeenAt: nil, tag: studio.tag, bundleID: nil, accountTrust: .sameAccount)
        }
        #expect(CloudTreeNodeBuilder.orderedDeviceInfos([offline, connected]).map(\.id) == [connected.id, offline.id])

        connected.linkState = .offline
        #expect(CloudTreeNodeBuilder.orderedDeviceInfos([offline, connected]).map(\.id) == [offline.id, connected.id])
    }

    @Test("Ordering: online first, then name, then tag; cloud and local machines are never device rows")
    func ordering() {
        let infos = [
            info(laptop, name: "Laptop", online: false, linkState: .offline),
            info(SurfaceDeviceInstanceID(deviceID: "44444444-4444-4444-4444-444444444444", tag: "default"), name: "zeta", online: true, linkState: .connected),
            info(studio, name: "Alpha", online: true, linkState: .connected),
            cloudInfo("brave-otter"),
        ]
        #expect(CloudTreeNodeBuilder.orderedDeviceInfos(infos).map(\.name) == ["Alpha", "zeta", "Laptop"])
    }
}
