import AppKit
import CmuxSettings
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud sidebar Ports status controls", .serialized)
struct CloudPortsVPNAffordanceTests {
    @Test("Empty Ports rows expose contextual status and actions",
          arguments: [SurfaceLinkState.connected, .notApplicable, .connecting, .error, .asleep, .unavailable])
    func discoveryRowsStayUnchanged(link: SurfaceLinkState) {
        let node = emptyPorts(link: link)
        let cell = CloudTreeCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        cell.configure(node: node, machineActions: machineActions(), nodeActions: nodeActions())
        cell.layoutSubtreeIfNeeded()
        guard case .placeholder(_, let placeholder) = node.kind,
              let status = placeholder.portStatus else {
            Issue.record("Ports status must carry contextual presentation")
            return
        }
        #expect(cell.accessibilityLabel()?.contains(status.title) == true)
        let buttons = descendants(of: cell).compactMap { $0 as? NSButton }
        #expect(buttons.count == 1)
        #expect(buttons.allSatisfy { $0.isHidden == (status.action == .none) })
        #expect(CloudTreeRowHeight(style: .defaultStyle).height(of: node, in: NSOutlineView()) >= CloudTreeStyle.defaultStyle.rowHeight)
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
