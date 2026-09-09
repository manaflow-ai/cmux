import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The machine row's context menu is where the Cloud sidebar offers a
/// machine's verbs, so it lists only verbs the product honors end to end.
/// Disk resize is not one of them yet
/// (https://github.com/manaflow-ai/cmux/issues/12156): the menu used to grow
/// an "Increase Disk" submenu whose targets fired an unsupported resize. This
/// pins the exact verb list a machine row offers and proves the surviving
/// verbs still reach their closures.
@MainActor
@Suite("Cloud tree machine context menu")
struct CloudTreeMachineMenuTests {
    private static let machineID = "brave-otter"

    @Test("A machine's menu lists its verbs with no disk resize item or submenu")
    func machineMenuOffersOnlySupportedVerbs() throws {
        let recorder = CloudTreeMenuVerbRecorder()
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: Self.machineActions(recording: recorder),
            nodeActions: Self.nodeActions(recording: recorder),
            expansionStore: CloudTreeExpansionStore(
                defaults: UserDefaults(suiteName: "cloud-tree-menu-\(UUID().uuidString)")!
            ),
            tabDragTransferRegistry: { nil }
        )
        // The container owns the outline view the coordinator only holds
        // weakly; keep it alive for the whole menu round-trip.
        let container = CloudTreeContainerView(coordinator: coordinator)
        defer { withExtendedLifetime(container) {} }
        coordinator.apply(nodes: [Self.machineNode()])

        let menu = try #require(coordinator.contextMenu(forRow: 0))
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == [
            Self.title("machines.menu.openShell", "Open Shell"),
            Self.title("cloudTree.menu.newWorkspace", "New Workspace"),
            Self.title("cloudTree.menu.openFullClient", "Open Full cmux-tui Client"),
            Self.title("cloudTree.menu.refresh", "Refresh"),
            Self.title("machines.menu.rename", "Rename\u{2026}"),
            Self.title("machines.menu.copyIPAddress", "Copy IP Address"),
            Self.title("machines.menu.status", "Status"),
            Self.title("machines.menu.checkpoint", "Checkpoint"),
            Self.title("machines.menu.fork", "Fork"),
            Self.title("machines.menu.delete", "Delete\u{2026}"),
        ])
        // Every verb is a leaf: nothing opens a submenu of targets.
        #expect(menu.items.allSatisfy { $0.submenu == nil })

        // The verbs that stay are still wired, not merely titled.
        try Self.choose(Self.title("machines.menu.openShell", "Open Shell"), in: menu)
        #expect(recorder.newTerminals == [.cloud(Self.machineID)])
        try Self.choose(Self.title("machines.menu.checkpoint", "Checkpoint"), in: menu)
        #expect(recorder.commands.map { $0.id } == [Self.machineID])
        #expect(recorder.commands.map { $0.verb } == [["vm", "snapshot"]])
        try Self.choose(Self.title("machines.menu.delete", "Delete\u{2026}"), in: menu)
        #expect(recorder.deletions == [Self.machineID])
    }

    /// The same catalog lookup the outline uses for its items, so the
    /// expectation holds in every locale.
    private static func title(_ key: StaticString, _ defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue)
    }

    /// Fires the item the way AppKit does when the person picks it.
    private static func choose(_ title: String, in menu: NSMenu) throws {
        let item = try #require(menu.items.first { $0.title == title })
        let action = try #require(item.action)
        #expect(NSApp.sendAction(action, to: item.target, from: item))
    }

    /// A ready Base machine on a paid plan with every provider verb, an
    /// address to copy, and a disk reading: the reading is a stat, never an
    /// affordance.
    private static func machineNode() -> CloudTreeNode {
        var machine = MachineSnapshot(
            id: machineID,
            provider: "freestyle",
            image: "cmux-devbox:devbox-20260828b",
            isDesktop: false,
            activity: .ready,
            createdAt: nil,
            label: "Big Machine"
        )
        machine.privateAddress = "10.99.0.7"
        machine.stats = VMStats(
            state: .awake,
            sampledAt: Date(timeIntervalSince1970: 1_787_400_000),
            cpus: 4,
            cpuPercent: 2.5,
            loadAverage1m: 0.2,
            memoryTotalMb: 8_192,
            memoryUsedMb: 1_024,
            diskTotalMb: 32 * 1_024,
            diskUsedMb: 6 * 1_024
        )
        return CloudTreeNode(id: CloudTreeNodeBuilder.nodeID(machine: .cloud(machineID)), kind: .machine(machine, nil))
    }

    private static func machineActions(recording recorder: CloudTreeMenuVerbRecorder) -> MachineRowActions {
        MachineRowActions(
            openShell: { _ in },
            openDesktop: { _ in },
            runCommand: { id, verb in recorder.commands.append((id: id, verb: verb)) },
            confirmDelete: { recorder.deletions.append($0) },
            promptRename: { _, _ in },
            promptUpgrade: {}
        )
    }

    private static func nodeActions(recording recorder: CloudTreeMenuVerbRecorder) -> CloudTreeNodeActions {
        CloudTreeNodeActions(
            project: { _, _, _ in },
            projectRemoteView: { _, _, _, _ in },
            projectInLocalWorkspace: { _, _ in },
            projectRemoteViewInLocalWorkspace: { _, _, _ in },
            newTerminal: { machine, _ in recorder.newTerminals.append(machine) },
            openGroup: { _, _, _, _ in },
            openGroupAsWorkspace: { _, _, _ in },
            newWorkspace: { _ in },
            closeTerminal: { _ in },
            closeWorkspace: { _, _ in },
            renameWorkspace: { _, _ in },
            renameTerminal: { _, _ in },
            selectLocalWorkspace: { _ in },
            copyToPasteboard: { _ in },
            copyPortLink: { _ in },
            refresh: {}
        )
    }
}

/// Verbs the menu items fired, so the test proves each surviving item is
/// wired to its closure and not merely titled.
@MainActor
private final class CloudTreeMenuVerbRecorder {
    var newTerminals: [SurfaceMachineID] = []
    var commands: [(id: String, verb: [String])] = []
    var deletions: [String] = []
}
