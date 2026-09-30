import CmuxCloud
import AppKit
import CmuxFoundation
import CmuxSurfaceCatalogModel
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The Cloud tab's section headers carry hover-only trailing actions for My
/// Devices. Cloud Machines uses one persistent create row directly under its
/// header so the category has a single, discoverable creation affordance.
@MainActor
@Suite("Cloud sidebar: section header actions")
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

    @Test("Cloud Machines uses one persistent create row instead of a duplicate header action", arguments: [220.0, 380.0])
    func cloudMachinesCreateActionIsPersistent(width: Double) throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let tree = try Tree(fixture: fixture, width: width, canCreateCloudMachine: true)
        let header = try tree.cell(for: tree.cloudSection)
        #expect(header.subviews.first { $0 is CloudTreeRowControlsHostingView } == nil)
        let action = try #require(tree.cloudSection.children.first { if case .createAction(.newCloudVM) = $0.kind { true } else { false } })
        let actionCell = try tree.cell(for: action)
        #expect(actionCell.accessibilityLabel() == CloudTreeCreateAction.newCloudVM.title)
        #expect(tree.cloudSection.children.filter { if case .createAction(.newCloudVM) = $0.kind { true } else { false } }.count == 1)
    }

    @Test("Cloud Machines has no hover controls when creation is unavailable")
    func cloudMachinesHasNoHeaderActionWhenUnavailable() throws {
        #expect(!CloudTreeRowHoverButtons.hasButtons(for: .cloudMachinesSection(canCreateMachine: false)))
        #expect(!CloudTreeRowHoverButtons.hasButtons(for: .cloudMachinesSection(canCreateMachine: true)))
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let tree = try Tree(fixture: fixture, width: 380)
        let header = try tree.cell(for: tree.cloudSection)
        #expect(header.subviews.first { $0 is CloudTreeRowControlsHostingView } == nil)
    }

    /// The Devices menu remains in the accessibility tree while faded; the
    /// persistent Cloud Machine action is exposed by its own row instead.
    @Test("Faded device header actions stay in the accessibility tree with their labels")
    func fadedHeaderActionsStayAccessible() async throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let tree = try Tree(fixture: fixture, width: 380, canCreateCloudMachine: true)
        let devicesHeader = try tree.cell(for: tree.devicesSection)
        let menuHost = try #require(try Self.controls(in: devicesHeader) as? CloudTreeRowControlsHostingView)
        menuHost.rootView = AnyView(menuHost.rootView.environment(\.accessibilityEnabled, true))
        #expect(menuHost.alphaValue == 0)

        var menu: NSObject?
        let published = await AppKitTestEventPump().waitUntil(timeout: .seconds(5)) {
            fixture.container.layoutSubtreeIfNeeded()
            fixture.window.displayIfNeeded()
            menu = Self.accessibilityElement("DevicesOptionsMenu", in: devicesHeader)
            return menu != nil
        }
        try #require(published, "Faded device header controls must stay in the accessibility tree")
        let menuElement = try #require(menu)
        #expect(Self.accessibilityAttribute(.description, getter: "accessibilityLabel", of: menuElement) as? String == "Manage My Devices")
        #expect(menuHost.alphaValue == 0)
    }

    /// The row-level controls used to reserve two lines for "Change these
    /// options in the ⋯ menu next to My Devices." beneath the toggles.
    @Test(
        "My Devices controls size to their rows, with no space kept for the removed ⋯ hint",
        arguments: [
            (0, CloudTreeDevicesSection(discoveryEnabled: true, incomingAccessEnabled: false)),
            (0, CloudTreeDevicesSection(discoveryEnabled: false, incomingAccessEnabled: false)),
            (2, CloudTreeDevicesSection(discoveryEnabled: true, incomingAccessEnabled: false)),
            (0, CloudTreeDevicesSection(discoveryEnabled: true, incomingAccessEnabled: true))
        ]
    )
    func devicesControlsHaveNoHintSpace(listedMacs: Int, section: CloudTreeDevicesSection) throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let tree = try Tree(fixture: fixture, width: 380, devices: Self.onlineMacs(listedMacs), devicesSection: section)
        let controls = try #require(tree.devicesSection.children.first {
            if case .devicesEmpty = $0.kind { true } else { false }
        })
        // "No other Macs yet", then both independent actions in every state.
        let inlineRows = (listedMacs == 0 ? 1 : 0) + 2
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

    /// The element an assistive client reaches for `identifier`, found through
    /// accessibility children rather than the view hierarchy.
    static func accessibilityElement(_ identifier: String, in root: NSView) -> NSObject? {
        var pending: [NSObject] = [root]
        var visited = Set<ObjectIdentifier>()
        while !pending.isEmpty {
            let element = pending.removeFirst()
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            if element !== root,
               accessibilityAttribute(.identifier, getter: "accessibilityIdentifier", of: element) as? String == identifier {
                return element
            }
            let children = accessibilityAttribute(.children, getter: "accessibilityChildren", of: element) as? [Any]
            pending += NSAccessibility.unignoredChildren(from: children ?? []).compactMap { $0 as? NSObject }
        }
        return nil
    }

    /// Reads an attribute the way `SidebarAccessibilityTreeWalk` does: SwiftUI
    /// nodes answer either the modern getter or the legacy attribute API.
    static func accessibilityAttribute(_ attribute: NSAccessibility.Attribute, getter: String, of element: NSObject) -> Any? {
        let modern = NSSelectorFromString(getter)
        if element.responds(to: modern), let value = element.perform(modern)?.takeUnretainedValue() {
            return value
        }
        let names = NSSelectorFromString("accessibilityAttributeNames")
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        guard element.responds(to: names), element.responds(to: legacy),
              let attributes = element.perform(names)?.takeUnretainedValue() as? [String],
              attributes.contains(attribute.rawValue) else { return nil }
        return element.perform(legacy, with: attribute.rawValue)?.takeUnretainedValue()
    }

    /// `count` other Macs that are online and trusted, as the device catalog lists them.
    static func onlineMacs(_ count: Int) -> [SurfaceMachineInfo] {
        (0..<count).map { index in
            let instance = SurfaceDeviceInstanceID(deviceID: "4444444\(index)-4444-4444-4444-444444444444", tag: "default")
            return SurfaceMachineInfo(
                id: .device(instance), name: "Mac \(index)", status: "running", image: nil, hasDesktop: false,
                memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
                cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil, remoteWorkspaces: [],
                presence: SurfaceDevicePresence(
                    state: .online, lastSeenAt: nil, tag: "default", bundleID: "com.cmuxterm.app", accountTrust: .sameAccount
                )
            )
        }
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
            devices: [SurfaceMachineInfo] = [],
            devicesSection: CloudTreeDevicesSection = .init(),
            canCreateCloudMachine: Bool = false
        ) throws {
            self.fixture = fixture
            fixture.window.setContentSize(NSSize(width: width, height: 620))
            nodes = CloudTreeCreateActionBuilder.add(to: CloudTreeNodeBuilder.nodes(
                machines: machines,
                snapshot: SurfaceCatalogSnapshot(machines: devices, resources: [], projections: []),
                localWorkspaces: [], includeLocalMachine: false,
                source: .cloudWithDevicesSection, devicesSection: devicesSection,
                canCreateCloudMachine: canCreateCloudMachine
            ))
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
