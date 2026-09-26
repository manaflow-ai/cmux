import CmuxCloud
import AppKit
import CmuxFoundation
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The Cloud tab's section headers carry hover-only trailing actions: My
/// Devices' ⋯ options menu. The action host is always laid out and stays in
/// the hit-test and accessibility trees; only its alpha follows hover, so the
/// header title and count never shift.
@MainActor
@Suite("Cloud sidebar: hover-only section header actions")
struct CloudTreeHeaderActionsTests {
    @Test("My Devices' ⋯ appears only while its header is hovered and stays clickable at rest", arguments: [220.0, 380.0])
    func devicesOptionsMenuIsHoverOnly(width: Double) throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let tree = try Tree(fixture: fixture, width: width)
        let header = try tree.cell(for: tree.devicesSection)
        let menu = try Self.controls(in: header)
        let title = try Self.display(in: header)
        let restingTitleFrame = title.frame

        #expect(!menu.isHidden)
        #expect(menu.alphaValue == 0)
        // Invisible is not unreachable: the ⋯ keeps its hit area and its place
        // in the accessibility tree, so a click or VoiceOver press still opens it.
        let hit = try tree.hit(atCenterOf: menu)
        #expect(hit.isDescendant(of: menu))
        #expect(tree.outline.validateProposedFirstResponder(hit, for: nil))

        header.setHovered(true)
        header.layoutSubtreeIfNeeded()
        #expect(menu.alphaValue == 1)
        #expect(title.frame == restingTitleFrame)

        header.setHovered(false)
        header.layoutSubtreeIfNeeded()
        #expect(menu.alphaValue == 0)
        #expect(!menu.isHidden)
        #expect(title.frame == restingTitleFrame)
    }

    @Test("A reused header cell starts at rest, whatever the previous row's hover state")
    func reusedHeaderStartsAtRest() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let tree = try Tree(fixture: fixture, width: 380)
        let header = try tree.cell(for: tree.devicesSection)
        let menu = try Self.controls(in: header)
        header.setHovered(true)
        #expect(menu.alphaValue == 1)

        header.prepareForReuse()
        #expect(menu.alphaValue == 0)
        header.configure(
            node: tree.devicesSection,
            machineActions: fixture.coordinator.machineActions,
            nodeActions: fixture.coordinator.nodeActions
        )
        #expect(menu.alphaValue == 0)
        header.setHovered(true)
        #expect(menu.alphaValue == 1)
    }

    /// The row-level controls used to reserve two lines for "Change these
    /// options in the ⋯ menu next to My Devices." beneath the toggles.
    @Test(
        "My Devices controls size to their rows, with no space kept for the removed ⋯ hint",
        arguments: [
            CloudTreeDevicesSection(count: 0, discoveryEnabled: true, incomingAccessEnabled: false),
            CloudTreeDevicesSection(count: 0, discoveryEnabled: false, incomingAccessEnabled: false),
            CloudTreeDevicesSection(count: 2, discoveryEnabled: true, incomingAccessEnabled: false),
            CloudTreeDevicesSection(count: 0, discoveryEnabled: true, incomingAccessEnabled: true)
        ]
    )
    func devicesControlsHaveNoHintSpace(section: CloudTreeDevicesSection) throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let tree = try Tree(fixture: fixture, width: 380, devicesSection: section)
        let controls = try #require(tree.devicesSection.children.first {
            if case .devicesEmpty = $0.kind { true } else { false }
        })
        let inlineRows = (section.count == 0 ? 1 : 0)
            + (section.discoveryEnabled ? 0 : 1)
            + (section.incomingAccessEnabled ? 0 : 1)
        let style = tree.outline.treeStyle
        // Each inline row plus the 2 pt top and bottom inset, nothing more.
        let expected = GlobalFontMagnification.scaledSize(CGFloat(inlineRows) * style.rowHeight + 4)
        #expect(fixture.coordinator.outlineView(tree.outline, heightOfRowByItem: controls) == expected)
        let bundle = Bundle(for: CloudTreeCellView.self)
        #expect(bundle.localizedString(forKey: "devices.options.hint", value: "∅", table: "Localizable") == "∅")
    }

    /// Opening a row's menu hands pointer tracking to the menu. The exit and
    /// move events it produces, and any reload behind it, must not fade the
    /// control that opened it. Hover follows the pointer again once it closes.
    @Test("An open menu keeps its row hovered until it closes")
    func openMenuPinsHover() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let tree = try Tree(fixture: fixture, width: 380, machines: [Self.fleetRow("brave-otter")])
        let machineNode = try #require(tree.cloudSection.children.first { $0.id.contains("brave-otter") })
        tree.move(to: machineNode)
        let machineControls = try Self.controls(in: tree.cell(for: machineNode))
        #expect(machineControls.alphaValue == 1)

        let menu = NSMenu()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        tree.move(to: tree.devicesSection)
        tree.exit()
        #expect(try Self.controls(in: tree.cell(for: machineNode)).alphaValue == 1)
        #expect(try Self.controls(in: tree.cell(for: tree.devicesSection)).alphaValue == 0)

        tree.outline.reloadData()
        fixture.container.layoutSubtreeIfNeeded()
        #expect(try Self.controls(in: tree.cell(for: machineNode)).alphaValue == 1)

        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        tree.move(to: tree.devicesSection)
        #expect(try Self.controls(in: tree.cell(for: machineNode)).alphaValue == 0)
        #expect(try Self.controls(in: tree.cell(for: tree.devicesSection)).alphaValue == 1)
    }

    static func controls(in cell: CloudTreeCellView) throws -> NSView {
        try #require(cell.subviews.first { $0 is CloudTreeRowControlsHostingView })
    }

    static func display(in cell: CloudTreeCellView) throws -> NSView {
        try #require(cell.subviews.first { $0 is CloudTreePassthroughHostingView })
    }

    static func fleetRow(_ id: String) -> MachineSnapshot {
        MachineSnapshot(id: id, provider: "freestyle", image: "sh-1", isDesktop: false, activity: .ready, createdAt: nil, label: id)
    }

    /// The merged Cloud tab, rendered by the production outline and fully expanded.
    @MainActor
    struct Tree {
        let fixture: CloudSidebarOrderingFixture
        let outline: CloudTreeNSOutlineView
        let nodes: [CloudTreeNode]

        init(
            fixture: CloudSidebarOrderingFixture,
            width: Double,
            machines: [MachineSnapshot] = [],
            devicesSection: CloudTreeDevicesSection = .init()
        ) throws {
            self.fixture = fixture
            fixture.window.setContentSize(NSSize(width: width, height: 620))
            nodes = CloudTreeNodeBuilder.nodes(
                machines: machines, snapshot: .empty, localWorkspaces: [], includeLocalMachine: false,
                source: .cloudWithDevicesSection, devicesSection: devicesSection
            )
            fixture.coordinator.apply(nodes: nodes)
            outline = try #require(fixture.coordinator.outlineView)
            outline.expandItem(nil, expandChildren: true)
            fixture.container.layoutSubtreeIfNeeded()
        }

        var cloudSection: CloudTreeNode {
            nodes.first { $0.id == "cloud-machines-section" }!
        }

        var devicesSection: CloudTreeNode {
            nodes.first { $0.id == CloudTreeNodeBuilder.devicesSectionNodeID }!
        }

        func cell(for node: CloudTreeNode) throws -> CloudTreeCellView {
            let row = outline.row(forItem: node)
            try #require(row >= 0)
            let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? CloudTreeCellView)
            cell.layoutSubtreeIfNeeded()
            return cell
        }

        func hit(atCenterOf view: NSView) throws -> NSView {
            let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            return try #require(outline.hitTest(outline.superview!.convert(center, from: nil)))
        }

        /// Delivers the tracking-area move the pointer produces over `node`'s row.
        func move(to node: CloudTreeNode) {
            let rect = outline.rect(ofRow: outline.row(forItem: node))
            let location = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
            )!
            outline.mouseMoved(with: event)
        }

        /// Delivers the tracking-area exit a menu window produces when it opens over the row.
        func exit() {
            let event = NSEvent.enterExitEvent(
                with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
            )!
            outline.mouseExited(with: event)
        }
    }
}
