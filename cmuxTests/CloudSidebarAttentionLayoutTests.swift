import AppKit
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud sidebar attention layout")
struct CloudSidebarAttentionLayoutTests {
    @Test("Read and unread rows differ only in the leading slot, even pinned and narrow",
          arguments: [140.0, 300.0], ["workspace", "terminal"])
    func attentionPrecedesIcon(width: Double, kind: String) throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        fixture.coordinator.apply(nodes: fixture.nodes())
        let outline = try #require(fixture.coordinator.outlineView)
        let readNode = try #require(CloudTreeNodeBuilder.flattened(fixture.nodes()).first { $0.structureTag == kind })
        let unreadNode = try #require(CloudTreeNodeBuilder.flattened(fixture.nodes(unread: ["term_ws_1"]))
            .first { $0.id == readNode.id })
        let cell = try #require(outline.view(atColumn: 0, row: outline.row(forItem: readNode), makeIfNecessary: true) as? CloudTreeCellView)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 40))
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        cell.removeFromSuperview()
        cell.frame = host.bounds
        host.addSubview(cell)
        readNode.isPinned = true
        unreadNode.isPinned = true
        let read = try render(cell, node: readNode, fixture: fixture)
        let unread = try render(cell, node: unreadNode, fixture: fixture)
        #expect(read.pixelsWide == unread.pixelsWide)
        #expect(read.pixelsHigh == unread.pixelsHigh)
        var changedX: [Int] = []
        for y in 0..<min(read.pixelsHigh, unread.pixelsHigh) {
            for x in 0..<min(read.pixelsWide, unread.pixelsWide) {
                let a = try #require(read.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let b = try #require(unread.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let difference = abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent) + abs(a.alphaComponent - b.alphaComponent)
                if difference > 0.15 { changedX.append(x) }
            }
        }
        let right = try #require(changedX.max(), "The unread indicator must actually render")
        let scale = Double(unread.pixelsWide) / width
        let contentLeading = CloudTreeRowGrid.disclosureGap - CloudTreeNSOutlineView.cellShift
        #expect(Double(right) / scale < Double(contentLeading) + 8,
                "The dot must be before the icon; pin, title and trailing controls cannot shift")
        let cleared = try render(cell, node: readNode, fixture: fixture)
        #expect(cleared.tiffRepresentation == read.tiffRepresentation)
        #if compiler(>=6.2)
        Attachment.record(try #require(unread.representation(using: .png, properties: [:])), named: "leading-dot-\(kind)-\(Int(width)).png")
        #endif
    }

    @Test("Collapsed folders retain descendant attention and hover controls at narrow widths")
    func collapsedFolderAttention() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        fixture.window.setContentSize(NSSize(width: 220, height: 560))
        let nodes = fixture.nodes(unread: ["term_ws_2"])
        fixture.coordinator.apply(nodes: nodes)
        let outline = try #require(fixture.coordinator.outlineView)
        let folder = try #require(CloudTreeNodeBuilder.flattened(nodes).first { $0.id == fixture.folderID("ws_2") })
        outline.collapseItem(folder)
        #expect(!outline.isItemExpanded(folder))
        #expect(folder.hasUnreadAttention)
        let cell = try #require(outline.view(atColumn: 0, row: outline.row(forItem: folder), makeIfNecessary: true) as? CloudTreeCellView)
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        cell.mouseEntered(with: event)
        try fixture.attachScreenshot(named: "collapsed-folder-unread-hover-narrow")
        let clear = fixture.nodes()
        fixture.coordinator.apply(nodes: clear)
        #expect(!CloudTreeNodeBuilder.flattened(clear).contains { $0.hasUnreadAttention })
        try fixture.attachScreenshot(named: "collapsed-folder-read-hover-narrow")
    }

    @Test("Targeted refresh includes the collapsed folder when descendant attention changes")
    func collapsedFolderIsInvalidatedByDescendantReadChanges() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let read = fixture.nodes()
        fixture.coordinator.apply(nodes: read)
        let outline = try #require(fixture.coordinator.outlineView)
        let folder = try #require(CloudTreeNodeBuilder.flattened(read).first { $0.id == fixture.folderID("ws_2") })
        outline.collapseItem(folder)
        let before = CloudTreeNodeBuilder.contentSignature(read)
        let unread = CloudTreeNodeBuilder.contentSignature(fixture.nodes(unread: ["term_ws_2"]))
        let arrival = CloudTreeRowUpdate(previous: before, next: unread)
        #expect(arrival.changedNodeIDs.contains(folder.id))
        #expect(arrival.rowIndexes(in: outline).contains(outline.row(forItem: folder)))
        #expect(!arrival.changedNodeIDs.contains(fixture.folderID("ws_1")))
        let clear = CloudTreeRowUpdate(previous: unread, next: before)
        #expect(clear.rowIndexes(in: outline).contains(outline.row(forItem: folder)))
        folder.isPinned = true
        let pinned = CloudTreeRowUpdate(previous: before, next: CloudTreeNodeBuilder.contentSignature(read))
        #expect(pinned.rowIndexes(in: outline).contains(outline.row(forItem: folder)))
    }

    private func render(_ cell: CloudTreeCellView, node: CloudTreeNode, fixture: CloudSidebarOrderingFixture) throws -> NSBitmapImageRep {
        cell.configure(node: node, machineActions: fixture.coordinator.machineActions, nodeActions: fixture.coordinator.nodeActions)
        cell.layoutSubtreeIfNeeded()
        cell.displayIfNeeded()
        let bitmap = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
        cell.cacheDisplay(in: cell.bounds, to: bitmap)
        return bitmap
    }
}
