import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud VPN row height invalidation")
struct CloudVPNRowHeightTests {
    @Test("Live resize looks up only empty Ports callouts at sidebar scale", arguments: [20, 100, 1_000])
    func resizeLookupCostDependsOnlyOnCallouts(otherRowCount: Int) throws {
        try withCoordinator { coordinator in
            let empty = placeholder(id: "empty", isEmptyPorts: true)
            let hidden = placeholder(id: "hidden", isEmptyPorts: true)
            let otherRows = (0..<otherRowCount).map { placeholder(id: "other-\($0)") }
            coordinator.apply(nodes: [group(id: "ports", child: empty), group(id: "collapsed", child: hidden)] + otherRows)
            let outline = CloudVPNRowHeightRecordingOutline()
            outline.visibleNodes = otherRows + [empty]

            for _ in 0..<5 { coordinator.updateCloudVPNRowHeights(in: outline) }

            #expect(outline.itemQueries == 0)
            #expect(outline.rowQueries.count == 10)
            #expect(outline.invalidatedRows == IndexSet(integer: otherRowCount))
            let targetedOnlyCallouts = outline.rowQueries.allSatisfy { $0 === empty || $0 === hidden }
            #expect(targetedOnlyCallouts)
        }
    }

    @Test("Content adoption targets retained nodes and removes disconnected placeholders")
    func contentUpdatesPreserveNativeIdentity() throws {
        try withCoordinator { coordinator in
            let retained = placeholder(id: "empty")
            coordinator.apply(nodes: [group(id: "ports", child: retained)])
            let outline = CloudVPNRowHeightRecordingOutline()
            outline.visibleNodes = [retained]
            coordinator.updateCloudVPNRowHeights(in: outline)
            #expect(outline.invalidatedRows.isEmpty)

            let replacement = placeholder(id: "empty", isEmptyPorts: true)
            coordinator.apply(nodes: [group(id: "ports", child: replacement)])
            outline.resetRecording()
            coordinator.updateCloudVPNRowHeights(in: outline)
            #expect(outline.rowQueries.count == 1)
            #expect(outline.rowQueries.first === retained)
            #expect(outline.invalidatedRows == IndexSet(integer: 0))

            coordinator.apply(nodes: [group(id: "ports", child: placeholder(id: "empty"))])
            outline.resetRecording()
            coordinator.updateCloudVPNRowHeights(in: outline)
            #expect(outline.rowQueries.isEmpty)
            #expect(outline.invalidatedRows.isEmpty)
        }
    }

    @Test("Collapsed callouts resolve their current rows after expansion and structural replacement")
    func expansionAndReplacementRefreshTargets() throws {
        try withCoordinator { coordinator in
            let original = placeholder(id: "empty", isEmptyPorts: true)
            coordinator.apply(nodes: [group(id: "ports", child: original)])
            let outline = CloudVPNRowHeightRecordingOutline()
            coordinator.updateCloudVPNRowHeights(in: outline)
            #expect(outline.invalidatedRows.isEmpty)

            outline.visibleNodes = [placeholder(id: "preceding"), original]
            outline.resetRecording()
            coordinator.updateCloudVPNRowHeights(in: outline)
            #expect(outline.invalidatedRows == IndexSet(integer: 1))

            let replacement = placeholder(id: "replacement", isEmptyPorts: true)
            coordinator.apply(nodes: [group(id: "ports", child: replacement)])
            outline.visibleNodes = [replacement]
            outline.resetRecording()
            coordinator.updateCloudVPNRowHeights(in: outline)
            #expect(outline.rowQueries.first === replacement)
            #expect(outline.invalidatedRows == IndexSet(integer: 0))

            coordinator.showsCloudVPNWarning = false
            outline.resetRecording()
            coordinator.updateCloudVPNRowHeights(in: outline)
            #expect(outline.itemQueries == 0 && outline.rowQueries.isEmpty)
            #expect(outline.invalidatedRows.isEmpty)

            coordinator.apply(nodes: [])
            coordinator.showsCloudVPNWarning = true
            coordinator.updateCloudVPNRowHeights(in: outline)
            #expect(outline.rowQueries.isEmpty)
            #expect(outline.invalidatedRows.isEmpty)
        }
    }

    private func placeholder(id: String, isEmptyPorts: Bool = false) -> CloudTreeNode {
        CloudTreeNode(id: id, kind: .placeholder(machine: .cloud("test"), .init(
            text: isEmptyPorts ? "Empty" : "Connecting", style: .dimmed, isEmptyPorts: isEmptyPorts
        )))
    }

    private func group(id: String, child: CloudTreeNode) -> CloudTreeNode {
        CloudTreeNode(id: id, kind: .portsGroup(machine: .cloud("test")), children: [child])
    }

    private func withCoordinator(_ body: (CloudTreeOutlineView.Coordinator) throws -> Void) throws {
        let suite = "CloudVPNRowHeightTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: MachineRowActions(setupVPN: { _ in }, openShell: { _ in }, openDesktop: { _ in },
                runCommand: { _, _ in }, confirmDelete: { _ in }, promptRename: { _, _ in }, resizeDisk: { _, _ in }, promptUpgrade: {}),
            nodeActions: CloudTreeNodeActions(project: { _, _, _ in }, projectRemoteView: { _, _, _, _ in },
                projectInLocalWorkspace: { _, _ in }, projectRemoteViewInLocalWorkspace: { _, _, _ in }, newTerminal: { _, _ in },
                openGroup: { _, _, _, _ in }, openGroupAsWorkspace: { _, _, _ in }, newWorkspace: { _ in }, closeTerminal: { _ in },
                closeWorkspace: { _, _ in }, renameWorkspace: { _, _ in }, renameTerminal: { _, _ in }, selectLocalWorkspace: { _ in },
                copyToPasteboard: { _ in }, copyPortLink: { _ in }, refresh: {}),
            expansionStore: CloudTreeExpansionStore(defaults: defaults), tabDragTransferRegistry: { nil }
        )
        coordinator.showsCloudVPNWarning = true
        try body(coordinator)
    }
}
