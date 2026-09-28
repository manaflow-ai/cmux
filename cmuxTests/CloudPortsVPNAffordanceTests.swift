import AppKit
import CmuxSettings
import CmuxSurfaceCatalogModel
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud sidebar has no VPN setup controls", .serialized)
struct CloudPortsVPNAffordanceTests {
    @Test("Empty Ports rows preserve discovery status without setup controls",
          arguments: [SurfaceLinkState.connected, .notApplicable, .connecting, .error, .asleep, .unavailable])
    func discoveryRowsStayUnchanged(link: SurfaceLinkState) {
        let node = emptyPorts(link: link)
        let cell = CloudTreeCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        cell.configure(node: node, machineActions: machineActions(), nodeActions: nodeActions())
        cell.layoutSubtreeIfNeeded()
        #expect(cell.accessibilityLabel() == node.searchableTitle)
        #expect(descendants(of: cell).allSatisfy { !($0 is NSButton) })
        #expect(CloudTreeRowHeight(style: .defaultStyle).height(of: node, in: NSOutlineView()) == CloudTreeRowHeight(style: .defaultStyle).height(of: emptyPorts(link: .connecting), in: NSOutlineView()))
    }

    @Test("Ports headers contain no setup or help buttons", arguments: [140.0, 260.0])
    func portsHeaderHasNoSetup(width: Double) {
        let node = CloudTreeNode(id: "ports", kind: .portsGroup(machine: .cloud("test")))
        let cell = CloudTreeCellView(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        cell.configure(node: node, machineActions: machineActions(), nodeActions: nodeActions())
        cell.layoutSubtreeIfNeeded()
        #expect(cell.toolTip == nil)
        #expect(descendants(of: cell).allSatisfy { !($0 is NSButton) })
    }

    private func emptyPorts(link: SurfaceLinkState) -> CloudTreeNode {
        CloudMachineSurfacePresentation.emptyPorts(info: SurfaceMachineInfo(
            id: .cloud("test"), name: "test", status: "running", image: "base", hasDesktop: false,
            memoryMb: nil, diskMb: nil, linkState: link, linkError: link == .error ? "Link failed" : nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil
        ))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func machineActions() -> MachineRowActions {
        MachineRowActions( openShell: { _ in }, openDesktop: { _ in }, runCommand: { _, _ in },
            confirmDelete: { _ in }, promptRename: { _, _ in }, resizeDisk: { _, _ in }, resizeCPU: { _, _ in },
            resizeMemory: { _, _ in }, promptUpgrade: {})
    }

    private func nodeActions() -> CloudTreeNodeActions {
        CloudTreeNodeActions(project: { _, _, _ in }, projectRemoteView: { _, _, _, _ in },
            projectInLocalWorkspace: { _, _ in }, projectRemoteViewInLocalWorkspace: { _, _, _ in },
            newTerminal: { _, _ in }, openGroup: { _, _, _, _ in }, openGroupAsWorkspace: { _, _, _ in },
            newWorkspace: { _ in }, closeTerminal: { _ in }, closeWorkspace: { _, _ in }, renameWorkspace: { _, _ in },
            renameTerminal: { _, _ in }, selectLocalWorkspace: { _ in }, copyToPasteboard: { _ in }, copyPortLink: { _ in }, refresh: {})
    }
}
