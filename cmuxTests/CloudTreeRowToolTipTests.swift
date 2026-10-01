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

    @Test("An untitled terminal says its fallback before its secondary facts")
    func untitledTerminalRowIsLabelled() {
        let cell = Self.cell(presence: [])
        cell.configure(
            node: Self.terminalNode(title: "", machine: .local, detail: "/tmp/work"),
            machineActions: Self.machineActions(),
            nodeActions: Self.nodeActions()
        )
        #expect(cell.toolTip == "/tmp/work")
        #expect(cell.accessibilityLabel() == "terminal\n/tmp/work")
    }

    @Test("A titled terminal with no secondary facts has no redundant hover text")
    func bareTitledTerminalRowHasNoToolTip() {
        let cell = Self.cell(presence: [])
        cell.configure(
            node: Self.terminalNode(title: "build", machine: .local),
            machineActions: Self.machineActions(),
            nodeActions: Self.nodeActions()
        )
        #expect(cell.toolTip == nil)
        #expect(cell.accessibilityLabel() == "build")
    }

    @Test("A titled terminal keeps its secondary facts in hover text and accessibility")
    func titledTerminalRowKeepsDetails() {
        let cell = Self.cell(presence: [])
        cell.configure(
            node: Self.terminalNode(title: "build", machine: .local, detail: "/tmp/work"),
            machineActions: Self.machineActions(),
            nodeActions: Self.nodeActions()
        )
        #expect(cell.toolTip == "/tmp/work")
        #expect(cell.accessibilityLabel() == "build\n/tmp/work")
    }

    @Test("A display row names its transport on hover")
    func displayRowHasToolTip() throws {
        let node = Self.displayNode()
        let cell = Self.cell(presence: [])
        cell.configure(node: node, machineActions: Self.machineActions(), nodeActions: Self.nodeActions())
        let toolTip = try #require(cell.toolTip)
        #expect(toolTip.contains(":1"))
    }

    @Test("A port row explains its in-app action without suggesting a directly reachable private URL")
    func portRowHasToolTip() throws {
        let node = Self.portNode()
        let cell = Self.cell(presence: [])
        cell.configure(node: node, machineActions: Self.machineActions(), nodeActions: Self.nodeActions())
        let toolTip = try #require(cell.toolTip)
        #expect(toolTip == "Open in cmux. No VPN setup needed.")
        #expect(cell.accessibilityLabel()?.contains("Port 3000") == true)
    }

    @Test("An untitled browser row is still labelled for assistive technology")
    func untitledBrowserRowIsLabelled() throws {
        let node = Self.browserNode(title: "")
        let cell = Self.cell(presence: [])
        cell.configure(node: node, machineActions: Self.machineActions(), nodeActions: Self.nodeActions())
        #expect(cell.accessibilityLabel()?.isEmpty == false)
    }

    /// A renamed browser tab keeps its name in `remoteView.name`; `resource.title`
    /// goes on following the page and changes under it on the next navigation.
    /// The row draws the rename, so the hover text and the VoiceOver label have
    /// to draw it too, or the pointer and the screen reader report a title the
    /// sidebar is not showing.
    @Test("A renamed browser row reports the rename, not the page title")
    func renamedBrowserRowUsesChosenName() throws {
        let workspace = SurfaceRemoteWorkspace(id: "ws-1", name: "Work", index: 0, focused: true)
        let node = Self.browserNode(
            title: "Example Domain | docs",
            remoteView: SurfaceRemoteView(tabID: "tab-1", workspace: workspace, name: "Release notes")
        )
        let cell = Self.cell(presence: [])
        cell.configure(node: node, machineActions: Self.machineActions(), nodeActions: Self.nodeActions())
        let toolTip = try #require(cell.toolTip)
        #expect(toolTip.contains("Release notes"))
        #expect(toolTip.contains("Example Domain") == false)
        #expect(cell.accessibilityLabel()?.contains("Release notes") == true)
        #expect(cell.accessibilityLabel()?.contains("Example Domain") == false)
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
        #expect(content.accessibilityLabel.contains(machine.kindLabel))
        // The age, stated against a clock the test owns rather than against the
        // label's own text: comparing the label to `content.subtitle` would pass
        // for any subtitle at all, including an empty one.
        let older = CloudTreeMachineRowContent(
            machine: machine,
            style: .defaultStyle,
            now: now.addingTimeInterval(20 * 60 * 60)
        )
        #expect(content.accessibilityLabel != older.accessibilityLabel)
    }

    /// An unlabelled machine's `displayName` is its id, and `showsName` is false
    /// so the subtitle leaves the id out. Saying it twice is what a label that
    /// pasted the subtitle in unconditionally would do, and VoiceOver reads
    /// every word of it on every arrow key.
    @Test("An unlabelled machine says its id once")
    func unlabelledMachineDoesNotRepeatItsID() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let content = CloudTreeMachineRowContent(
            machine: Self.machine(now: now, label: nil),
            style: .defaultStyle,
            now: now
        )
        #expect(content.accessibilityLabel.components(separatedBy: "vm-abc").count - 1 == 1)
    }

    /// The surface catalog finds a machine before the fleet list names it and
    /// builds it with `image: info.image ?? ""`. The tooltip put that straight
    /// into its line list, so hovering such a row opened a popup with a blank
    /// line in the middle of it.
    @Test("A machine whose image is not known yet has no blank line in its hover text")
    func machineToolTipDropsAnEmptyImageLine() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let content = CloudTreeMachineRowContent(
            machine: Self.machine(now: now, image: ""),
            style: .defaultStyle,
            now: now
        )
        #expect(content.toolTip.contains("\n\n") == false)
        #expect(content.toolTip.hasSuffix("\n") == false)
        // The rest of the tooltip is unchanged: dropping the empty line must not
        // drop the facts around it.
        #expect(content.toolTip.contains("vm-abc"))
        #expect(content.toolTip.contains("build box"))
    }

    /// `CloudTreeBrowserDetail.text` returns the URL host, else the local
    /// workspace showing the page. A browser with neither has nothing past the
    /// title the row already draws, and a popup that repeats the row covers the
    /// rows under it while saying nothing.
    @Test("A browser row with nothing past its own title has no hover text")
    func bareBrowserRowHasNoToolTip() {
        let cell = Self.cell(presence: [])
        cell.configure(
            node: Self.browserNode(title: "Design docs", url: nil),
            machineActions: Self.machineActions(),
            nodeActions: Self.nodeActions()
        )
        #expect(cell.toolTip == nil)
    }

    /// The untitled case has no name anywhere: no rename, no page title. The row
    /// and the tooltip both fall back to the word "browser", so the tooltip has
    /// nothing past the row and must stay silent.
    @Test("An untitled browser row with no address does not pop its own placeholder back")
    func bareUntitledBrowserRowHasNoToolTip() {
        let cell = Self.cell(presence: [])
        cell.configure(
            node: Self.browserNode(title: "", url: nil),
            machineActions: Self.machineActions(),
            nodeActions: Self.nodeActions()
        )
        #expect(cell.toolTip == nil)
        // Still labelled: quiet for the pointer is not quiet for VoiceOver.
        #expect(cell.accessibilityLabel()?.isEmpty == false)
    }

    @Test("A port without a process name still explains that no VPN setup is needed")
    func barePortRowExplainsOpenAction() {
        let cell = Self.cell(presence: [])
        cell.configure(
            node: Self.barePortNode(),
            machineActions: Self.machineActions(),
            nodeActions: Self.nodeActions()
        )
        #expect(cell.toolTip == "Open in cmux. No VPN setup needed.")
        #expect(cell.accessibilityLabel() == "Port 3000, Open in cmux")
    }

    // MARK: - Fixtures

    /// Labelled, so `showsName` is true and the subtitle carries the id, and
    /// three hours old, so the relative age is a stable non-empty string.
    /// `image` is a parameter because the catalog builds a machine it found
    /// before the fleet list named it with `image: info.image ?? ""`.
    private static func machine(now: Date, image: String = "devbox", label: String? = "build box") -> MachineSnapshot {
        MachineSnapshot(
            id: "vm-abc",
            provider: "freestyle",
            image: image,
            isDesktop: false,
            activity: .ready,
            createdAt: now.addingTimeInterval(-3 * 60 * 60),
            label: label
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

    private static func terminalRow(
        title: String = "build",
        machine: SurfaceMachineID = .cloud("tooltip-test"),
        detail: String? = nil
    ) -> CloudTreeTerminalRow {
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term-1"),
            title: title,
            detail: detail,
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            remoteViews: nil,
            port: nil,
            url: nil
        )
        return CloudTreeTerminalRow(resource: resource, isOpen: false, viewBadge: nil)
    }

    private static func terminalNode(
        title: String = "build",
        machine: SurfaceMachineID = .cloud("tooltip-test"),
        detail: String? = nil
    ) -> CloudTreeNode {
        CloudTreeNode(
            id: "terminal/tooltip-test/term-1",
            kind: .terminal(terminalRow(title: title, machine: machine, detail: detail))
        )
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

    /// `url` is a parameter because a browser that has not navigated yet has
    /// none, and that is the row whose hover text has nothing to add.
    /// `remoteView` is a parameter because a renamed tab carries its name there
    /// and nowhere else: `resource.title` keeps following the page.
    private static func browserNode(
        title: String,
        url: String? = "https://example.com/docs",
        remoteView: SurfaceRemoteView? = nil
    ) -> CloudTreeNode {
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: .cloud("tooltip-test"), kind: .browser, key: "browser-1"),
            title: title,
            detail: nil,
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            remoteViews: nil,
            port: nil,
            url: url
        )
        return CloudTreeNode(
            id: "browser/tooltip-test/browser-1",
            kind: .browser(
                CloudTreeBrowserRow(
                    resource: resource,
                    isOpen: false,
                    workspaceTitle: nil,
                    remoteView: remoteView
                )
            )
        )
    }

    /// A forwarded port the daemon reported with no process name or detail.
    private static func barePortNode() -> CloudTreeNode {
        let resource = SurfaceResource(
            id: SurfaceResourceID(
                machine: .cloud("tooltip-test"),
                kind: .browser,
                key: SurfaceResourceID.portKey(3_000)
            ),
            title: "",
            detail: nil,
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
