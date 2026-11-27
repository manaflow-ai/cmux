import CmuxCloud
import AppKit
import CmuxCloudMachines
import CmuxFoundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud leading identity geometry")
struct CloudSidebarPinGeometryTests {
    @Test("The first machine pin repaints the native cell before a refresh", arguments: [220.0, 380.0])
    func machinePinRepaintsImmediately(width: Double) throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        fixture.window.setContentSize(NSSize(width: width, height: 560))
        let store = CloudMachinePinStore(defaults: fixture.defaults, scopeProvider: { "pin-render-test" })
        let catalog = fixture.snapshot()
        let model = MachinesPanelViewModel(
            createCoordinator: MachineCreateCoordinator(notifier: { _ in }),
            machinePinStore: store, catalogProvider: { catalog }
        )
        model.localWorkspacesProvider = { [] }
        model.readCatalog()
        let coordinator = fixture.coordinator
        coordinator.machineActions.setPinned = { id, pinned in model.setMachinePinned(pinned, id: id) }
        coordinator.apply(nodes: CloudTreeNodeBuilder.nodes(
            machines: model.sidebarMachines, snapshot: catalog, localWorkspaces: [], includeLocalMachine: false
        ))
        let outline = try #require(coordinator.outlineView)
        let machine = try #require(coordinator.nodes.first)
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        // Capture the production cell as the outline presents it. Do not call
        // configure or apply after the menu action: that would hide the delay.
        func capture() throws -> NSBitmapImageRep {
            fixture.container.layoutSubtreeIfNeeded()
            let cell = try #require(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? CloudTreeCellView)
            cell.layoutSubtreeIfNeeded()
            let bitmap = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
            cell.cacheDisplay(in: cell.bounds, to: bitmap)
            return bitmap
        }
        func choose(_ pinned: Bool) throws {
            let menu = try #require(coordinator.contextMenu(forRow: 0))
            let title = pinned
                ? String(localized: "machines.row.pin", defaultValue: "Pin Machine")
                : String(localized: "machines.row.unpin", defaultValue: "Unpin Machine")
            let item = try #require(menu.items.first { $0.title == title })
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        }
        let unpinned = try capture()
        try choose(true)
        #expect(store.isPinned(fixture.machine.rawValue))
        #expect(coordinator.nodes.first?.isPinned == true)
        let pinned = try capture()
        let changes = try #require(try differenceBounds(unpinned, pinned))
        let scale = CGFloat(pinned.pixelsWide) / outline.frameOfCell(atColumn: 0, row: 0).width
        #expect(changes.minX / scale < 20, "The leading pin must appear immediately")
        #expect(outline.selectedRow == 0)
        #expect(outline.isItemExpanded(machine))
        #if compiler(>=6.2)
        Attachment.record(try #require(pinned.representation(using: .png, properties: [:])), named: "machine-first-pin-\(Int(width)).png")
        #endif

        try choose(false)
        #expect(coordinator.nodes.first?.isPinned == false)
        let restored = try capture()
        #expect(restored.tiffRepresentation == unpinned.tiffRepresentation)
    }

    @Test("Pin reserves space before content at narrow and wide widths", arguments: [100.0, 320.0], [50, 75, 100, 150, 200])
    func leadingPin(width: Double, percent: Int) throws {
        let unpinned = try contentBounds(width: width, pinned: false, percent: percent, unread: false)
        let pinned = try contentBounds(width: width, pinned: true, percent: percent, unread: false)
        #expect(pinned.minX > unpinned.minX + 4, "The pin must precede the identity instead of consuming its trailing edge")
        #expect(abs(pinned.maxX - unpinned.maxX) <= 1, "Trailing alignment must not move when pinning")
    }

    @Test("Read rows stay compact and unread rows reserve the leading attention column",
          arguments: [50, 75, 100, 150, 200])
    func attentionSlotPrecedesContent(percent: Int) throws {
        let read = try contentBounds(width: 220, pinned: false, percent: percent, unread: false)
        let unread = try contentBounds(width: 220, pinned: false, percent: percent, unread: true)
        let slot = GlobalFontMagnification.scaledSize(CloudTreeStyle.compact.rowGrid.attentionSlot, percent: percent)
        #expect(read.minX <= 1, "Read rows must not reserve an empty leading gutter: \(read.minX)")
        #expect(unread.minX >= slot + 1,
                "Unread content must follow the leading attention slot: \(unread.minX), \(slot)")
    }

    @Test("Pin geometry follows the same magnification as row text")
    func pinMagnification() throws {
        let small = try contentBounds(width: 140, pinned: true, percent: 75, unread: false)
        let large = try contentBounds(width: 140, pinned: true, percent: 200, unread: false)
        #expect(large.minX > small.minX + 4)
        #expect(abs(large.maxX - small.maxX) <= 1)
    }

    @Test("Pinned folders retain the full accessible title and selection", arguments: [220.0, 380.0], [false, true])
    func longFolderTitle(width: Double, hovered: Bool) throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let title = "workspace-with-a-long-name-that-must-truncate-visually"
        fixture.window.setContentSize(NSSize(width: width, height: 560))
        fixture.coordinator.apply(nodes: fixture.nodes(titles: [title, "workspace-2"]))
        #expect(fixture.coordinator.organize(.pin, nodeID: fixture.folderID("ws_1")))
        let outline = try #require(fixture.coordinator.outlineView)
        let folder = try #require(CloudTreeNodeBuilder.flattened(fixture.coordinator.nodes).first { $0.id == fixture.folderID("ws_1") })
        let row = outline.row(forItem: folder)
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? CloudTreeCellView)
        cell.setHovered(hovered)
        #expect(cell.accessibilityLabel() == title)
        #expect(folder.isPinned)
        #expect(outline.selectedRow == row)
        try fixture.attachScreenshot(named: "pinned-long-folder-\(Int(width))-hover-\(hovered)-selected")
        outline.deselectAll(nil)
        try fixture.attachScreenshot(named: "pinned-long-folder-\(Int(width))-hover-\(hovered)-unselected")
    }

    @Test("Disclosure and hosted identity stay compact in the real outline")
    func compactDisclosure() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        fixture.coordinator.apply(nodes: fixture.nodes())
        let outline = try #require(fixture.coordinator.outlineView)
        let folder = try #require(CloudTreeNodeBuilder.flattened(fixture.coordinator.nodes).first { $0.id == fixture.folderID("ws_1") })
        let row = outline.row(forItem: folder)
        let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? CloudTreeCellView)
        cell.layoutSubtreeIfNeeded()
        let host = try #require(cell.subviews.first { $0 is CloudTreePassthroughHostingView })
        let gap = outline.convert(host.bounds, from: host).minX - outline.frameOfOutlineCell(atRow: row).maxX
        #expect(gap >= 0 && gap <= 4, "Rendered disclosure-to-content gap: \(gap)")
    }

    @Test("Reused native workspace cells keep the pin on the leading edge", arguments: [false, true], [false, true])
    func reusedCellLeadingPin(selected: Bool, hovered: Bool) throws {
        for width in [220.0, 380.0] {
            try checkReusedCell(width: width, selected: selected, hovered: hovered)
        }
    }

    private func checkReusedCell(width: Double, selected: Bool, hovered: Bool) throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        fixture.window.setContentSize(NSSize(width: width, height: 560))
        fixture.coordinator.apply(nodes: fixture.nodes(titles: ["x", "workspace-2"]))
        let outline = try #require(fixture.coordinator.outlineView)
        let folder = try #require(
            CloudTreeNodeBuilder.flattened(fixture.coordinator.nodes).first {
                $0.id == fixture.folderID("ws_1")
            }
        )
        let row = outline.row(forItem: folder)
        if selected {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            outline.deselectAll(nil)
        }
        let cell = try #require(
            outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? CloudTreeCellView
        )
        cell.setHovered(hovered)
        fixture.container.layoutSubtreeIfNeeded()
        let unpinned = try render(cell, node: folder, fixture: fixture)
        folder.isPinned = true
        let pinned = try render(cell, node: folder, fixture: fixture)
        let pixels = try #require(try differenceBounds(unpinned, pinned))
        let scale = CGFloat(pinned.pixelsWide) / cell.bounds.width
        let change = CGRect(x: pixels.minX / scale, y: pixels.minY / scale, width: pixels.width / scale, height: pixels.height / scale)
        // A leading pin shifts only the compact identity cluster. A trailing
        // accessory would put changed pixels at the far edge of this short row.
        #expect(change.minX < 80)
        #expect(change.maxX < 100, "Pin/content changes must stay in the leading identity cluster: \(change)")
        #expect(cell.accessibilityLabel() == "x")
        let state = "\(Int(width))-selected-\(selected)-hover-\(hovered)"
        #if compiler(>=6.2)
        Attachment.record(try #require(unpinned.representation(using: .png, properties: [:])), named: "native-unpinned-\(state).png")
        Attachment.record(try #require(pinned.representation(using: .png, properties: [:])), named: "native-pinned-\(state).png")
        Attachment.record("pin-change-bounds-points: \(change)", named: "native-pin-measurement-\(state).txt")
        #endif

        folder.isPinned = false
        let restored = try render(cell, node: folder, fixture: fixture)
        #expect(restored.tiffRepresentation == unpinned.tiffRepresentation)
    }

    private func render(
        _ cell: CloudTreeCellView,
        node: CloudTreeNode,
        fixture: CloudSidebarOrderingFixture
    ) throws -> NSBitmapImageRep {
        cell.configure(node: node, machineActions: fixture.coordinator.machineActions, nodeActions: fixture.coordinator.nodeActions)
        cell.layoutSubtreeIfNeeded()
        cell.displayIfNeeded()
        let bitmap = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
        cell.cacheDisplay(in: cell.bounds, to: bitmap)
        return bitmap
    }

    private func differenceBounds(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) throws -> CGRect? {
        guard lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh else { return nil }
        var bounds: CGRect?
        for y in 0..<lhs.pixelsHigh {
            for x in 0..<lhs.pixelsWide {
                guard let a = lhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let b = rhs.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let delta = abs(a.redComponent - b.redComponent)
                    + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent)
                    + abs(a.alphaComponent - b.alphaComponent)
                guard delta > 0.18 else { continue }
                let point = CGRect(x: x, y: y, width: 1, height: 1)
                bounds = bounds.map { $0.union(point) } ?? point
            }
        }
        return bounds
    }

    private func contentBounds(width: Double, pinned: Bool, percent: Int, unread: Bool) throws -> CGRect {
        // Fill the proposed content area so both edges measure layout, not
        // the intrinsic width and side bearings of a centered text glyph.
        let host = NSHostingView(rootView: Color.green
            .modifier(CloudSidebarRowDecoration(isPinned: pinned, showsAttentionSlot: true, hasUnreadNotification: unread))
            .accentColor(.blue)
            .environment(\.cmuxGlobalFontMagnificationPercent, percent))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 28)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var xs: [Int] = []
        for x in 0..<bitmap.pixelsWide {
            let color = try #require(bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            if color.greenComponent > color.redComponent + 0.15,
               color.greenComponent > color.blueComponent + 0.15 { xs.append(x) }
        }
        let scale = Double(bitmap.pixelsWide) / width
        let left = Double(try #require(xs.min())) / scale
        let right = Double(try #require(xs.max())) / scale
        #if compiler(>=6.2)
        Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: "pin-\(pinned)-\(Int(width))-\(percent)-unread-\(unread).png")
        #endif
        return CGRect(x: left, y: 0, width: right - left, height: 28)
    }
}
