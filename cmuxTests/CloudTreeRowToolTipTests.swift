import AppKit
import CmuxCloud
import CmuxSurfaceCatalogModel
import CmuxWorkspacePresence
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Hover text belongs to the cell, not to the hosted SwiftUI content: the
/// display host never hit-tests, so a `.help()` inside a row view can never be
/// reached by a pointer. These cover the rows whose secondary information was
/// only ever attached that way, plus the workspace row whose presence tooltip
/// was written and then reset inside the same `configure` call.
@MainActor
@Suite("Cloud rows carry their hover text on the cell", .serialized)
struct CloudTreeRowToolTipTests {
    @Test("A workspace row off-window still describes itself")
    func workspaceRowHasToolTip() throws {
        let node = Self.workspaceNode()
        let cell = Self.cell(presence: [])
        cell.configure(node: node, machineActions: Self.machineActions(), nodeActions: Self.nodeActions())
        let toolTip = try #require(cell.toolTip)
        #expect(toolTip.contains("api-refactor"))
        #expect(toolTip.contains("~/src/api"))
        #expect(toolTip.contains(CloudTreeRowContentView.count(3)))
    }

    @Test("A workspace row lists its collaborators without dropping its own name")
    func workspaceRowKeepsPresenceAndName() throws {
        let node = Self.workspaceNode()
        let cell = Self.cell(presence: [Self.participant(name: "Robin")])
        cell.configure(node: node, machineActions: Self.machineActions(), nodeActions: Self.nodeActions())
        let toolTip = try #require(cell.toolTip)
        #expect(toolTip.contains("api-refactor"))
        #expect(toolTip.contains("Robin"))
        #expect(cell.accessibilityLabel()?.contains("Robin") == true)
    }

    @Test("A workspace with nothing to add beyond its name has no hover text")
    func bareWorkspaceRowHasNoToolTip() {
        let node = CloudTreeNode(
            id: "workspace/tooltip-test/ws-bare",
            kind: .workspace(
                machine: .cloud("tooltip-test"),
                SurfaceRemoteWorkspace(id: "ws-bare", name: "workspace 2", index: 1, focused: false),
                terminalCount: 0,
                hiddenTabCount: 0,
                openIn: nil
            )
        )
        let cell = Self.cell(presence: [])
        cell.configure(node: node, machineActions: Self.machineActions(), nodeActions: Self.nodeActions())
        #expect(cell.toolTip == nil)
        #expect(cell.accessibilityLabel() == "workspace 2")
    }

    @Test("A placeholder row does not pop its own text back at the pointer")
    func placeholderRowHasNoToolTip() {
        let node = CloudTreeNode(
            id: "placeholder/tooltip-test/ports",
            kind: .placeholder(
                machine: .cloud("tooltip-test"),
                CloudTreePlaceholder(text: "No forwarded ports", style: .dimmed)
            )
        )
        let cell = Self.cell(presence: [])
        cell.configure(node: node, machineActions: Self.machineActions(), nodeActions: Self.nodeActions())
        #expect(cell.toolTip == nil)
    }

    @Test("A terminal row's directory and agent reach the pointer")
    func terminalRowHasToolTip() throws {
        let node = Self.terminalNode()
        let cell = Self.cell(presence: [])
        cell.configure(node: node, machineActions: Self.machineActions(), nodeActions: Self.nodeActions())
        let toolTip = try #require(cell.toolTip)
        let expected = CloudTreeTerminalRowContent(row: Self.terminalRow(), style: CloudTreeStyleStore.current).toolTip
        #expect(!expected.isEmpty)
        #expect(toolTip == expected)
    }

    @Test("A display row names its transport on hover")
    func displayRowHasToolTip() throws {
        let node = Self.displayNode()
        let cell = Self.cell(presence: [])
        cell.configure(node: node, machineActions: Self.machineActions(), nodeActions: Self.nodeActions())
        let toolTip = try #require(cell.toolTip)
        #expect(toolTip.contains(":1"))
    }

    @Test("A port row's full link survives a truncated title")
    func portRowHasToolTip() throws {
        let node = Self.portNode()
        let cell = Self.cell(presence: [])
        cell.configure(node: node, machineActions: Self.machineActions(), nodeActions: Self.nodeActions())
        let toolTip = try #require(cell.toolTip)
        #expect(toolTip.contains("http://10.0.0.4:3000"))
    }

    @Test("An untitled browser row is still labelled for assistive technology")
    func untitledBrowserRowIsLabelled() throws {
        let node = Self.browserNode(title: "")
        let cell = Self.cell(presence: [])
        cell.configure(node: node, machineActions: Self.machineActions(), nodeActions: Self.nodeActions())
        #expect(cell.accessibilityLabel()?.isEmpty == false)
    }

    @Test("Section headers keep their bare label", arguments: ["workspaces", "terminals", "ports"])
    func sectionHeadersHaveNoToolTip(kindName: String) {
        let machine = SurfaceMachineID.cloud("tooltip-test")
        let kind: CloudTreeNode.Kind = switch kindName {
        case "workspaces": .workspacesGroup(machine: machine)
        case "terminals": .terminalsPool(machine: machine, count: 2)
        default: .portsGroup(machine: machine)
        }
        let cell = Self.cell(presence: [])
        cell.configure(
            node: CloudTreeNode(id: kindName, kind: kind),
            machineActions: Self.machineActions(),
            nodeActions: Self.nodeActions()
        )
        #expect(cell.toolTip == nil)
    }

    @Test("A machine row's age is measured against the clock it was given")
    func machineSubtitleUsesInjectedClock() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let machine = Self.machine(now: now)
        let content = CloudTreeMachineRowContent(machine: machine, style: .defaultStyle, now: now)
        let hoursLater = CloudTreeMachineRowContent(
            machine: machine,
            style: .defaultStyle,
            now: now.addingTimeInterval(20 * 60 * 60)
        )
        #expect(content.subtitle != hoursLater.subtitle)
    }

    /// The compact preset is `machineRowLayout: .singleLine`, so the subtitle is
    /// the one place the machine id and its age are written, and the pointer
    /// reaches it through the tooltip. Assistive technology has no pointer, so
    /// leaving the subtitle out of the label is the same row saying less to the
    /// people who can least afford to lose it.
    @Test("A machine row tells assistive technology its id and its age, like its hover text does")
    func machineAccessibilityLabelCarriesIdentityAndAge() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let machine = Self.machine(now: now)
        let content = CloudTreeMachineRowContent(machine: machine, style: .defaultStyle, now: now)
        #expect(content.accessibilityLabel.contains("vm-abc"))
        #expect(content.accessibilityLabel.contains(content.subtitle))
    }

    // MARK: - Fixtures

    /// Labelled, so `showsName` is true and the subtitle carries the id, and
    /// three hours old, so the relative age is a stable non-empty string.
    private static func machine(now: Date) -> MachineSnapshot {
        MachineSnapshot(
            id: "vm-abc",
            provider: "freestyle",
            image: "devbox",
            isDesktop: false,
            activity: .ready,
            createdAt: now.addingTimeInterval(-3 * 60 * 60),
            label: "build box"
        )
    }

    private static func cell(presence: [WorkspacePresenceParticipant]) -> CloudTreeCellView {
        CloudTreeCellView(frame: NSRect(x: 0, y: 0, width: 260, height: 24), collaborators: { _, _ in presence })
    }

    private static func participant(name: String) -> WorkspacePresenceParticipant {
        WorkspacePresenceParticipant(id: "user-\(name)", displayName: name)
    }

    private static func workspaceNode() -> CloudTreeNode {
        let workspace = SurfaceRemoteWorkspace(
            id: "ws-1",
            name: "api-refactor",
            index: 0,
            focused: false,
            detail: "~/src/api"
        )
        return CloudTreeNode(
            id: "workspace/tooltip-test/ws-1",
            kind: .workspace(
                machine: .cloud("tooltip-test"),
                workspace,
                terminalCount: 3,
                hiddenTabCount: 0,
                openIn: nil
            )
        )
    }

    private static func terminalRow() -> CloudTreeTerminalRow {
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: .cloud("tooltip-test"), kind: .terminal, key: "term-1"),
            title: "build",
            detail: nil,
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            remoteViews: nil,
            port: nil,
            url: nil
        )
        return CloudTreeTerminalRow(resource: resource, isOpen: false, viewBadge: nil)
    }

    private static func terminalNode() -> CloudTreeNode {
        CloudTreeNode(id: "terminal/tooltip-test/term-1", kind: .terminal(terminalRow()))
    }

    private static func displayNode() -> CloudTreeNode {
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: .cloud("tooltip-test"), kind: .display, key: "display:1"),
            title: "",
            detail: nil,
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            remoteViews: nil,
            port: nil,
            url: nil
        )
        return CloudTreeNode(id: "display/tooltip-test/1", kind: .display(resource, openIn: nil, remoteView: nil))
    }

    private static func portNode() -> CloudTreeNode {
        let resource = SurfaceResource(
            id: SurfaceResourceID(
                machine: .cloud("tooltip-test"),
                kind: .browser,
                key: SurfaceResourceID.portKey(3_000)
            ),
            title: "3000",
            detail: "vite",
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            remoteViews: nil,
            port: 3_000,
            url: nil
        )
        return CloudTreeNode(
            id: "port/tooltip-test/3000",
            kind: .port(resource, url: "http://10.0.0.4:3000", openIn: nil)
        )
    }

    private static func browserNode(title: String) -> CloudTreeNode {
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: .cloud("tooltip-test"), kind: .browser, key: "browser-1"),
            title: title,
            detail: nil,
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            remoteViews: nil,
            port: nil,
            url: "https://example.com/docs"
        )
        return CloudTreeNode(
            id: "browser/tooltip-test/browser-1",
            kind: .browser(CloudTreeBrowserRow(resource: resource, isOpen: false, workspaceTitle: nil))
        )
    }

    private static func machineActions() -> MachineRowActions {
        MachineRowActions(
            openShell: { _ in }, openDesktop: { _ in }, runCommand: { _, _ in },
            confirmDelete: { _ in }, promptRename: { _, _ in }, resizeDisk: { _, _ in },
            resizeCPU: { _, _ in }, resizeMemory: { _, _ in }, promptUpgrade: {}
        )
    }

    private static func nodeActions() -> CloudTreeNodeActions {
        CloudTreeNodeActions(
            project: { _, _, _ in }, projectRemoteView: { _, _, _, _ in },
            projectInLocalWorkspace: { _, _ in }, projectRemoteViewInLocalWorkspace: { _, _, _ in },
            newTerminal: { _, _ in }, openGroup: { _, _, _, _ in }, openGroupAsWorkspace: { _, _, _ in },
            newWorkspace: { _ in }, closeTerminal: { _ in }, closeWorkspace: { _, _ in },
            renameWorkspace: { _, _ in }, renameTerminal: { _, _ in }, selectLocalWorkspace: { _ in },
            copyToPasteboard: { _ in }, copyPortLink: { _ in }, refresh: {}
        )
    }
}
