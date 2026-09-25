import CmuxCloud
import AppKit
import CmuxFoundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud sidebar attention layout", .serialized)
struct CloudSidebarAttentionLayoutTests {
    @Test("Unread indicators use a leading slot while read rows stay compact",
          arguments: [140.0, 300.0], ["workspace", "terminal"])
    func attentionPlacement(width: Double, kind: String) throws {
        for percent in [50, 75, 100, 150, 200] {
            for pinned in [false, true] {
                try attentionPlacement(width: width, kind: kind, percent: percent, pinned: pinned)
            }
        }
    }

    private func attentionPlacement(width: Double, kind: String, percent: Int, pinned: Bool) throws {
        let oldPercent = UserDefaults.standard.object(forKey: GlobalFontMagnification.percentKey)
        UserDefaults.standard.set(percent, forKey: GlobalFontMagnification.percentKey)
        defer {
            if let oldPercent { UserDefaults.standard.set(oldPercent, forKey: GlobalFontMagnification.percentKey) }
            else { UserDefaults.standard.removeObject(forKey: GlobalFontMagnification.percentKey) }
        }
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        fixture.coordinator.apply(nodes: fixture.nodes())
        let outline = try #require(fixture.coordinator.outlineView)
        let readNode = try #require(CloudTreeNodeBuilder.flattened(fixture.nodes()).first { $0.structureTag == kind })
        let unreadNode = try #require(CloudTreeNodeBuilder.flattened(fixture.nodes(unread: ["term_ws_1"]))
            .first { $0.id == readNode.id })
        let cell = try #require(outline.view(atColumn: 0, row: outline.row(forItem: readNode), makeIfNecessary: true) as? CloudTreeCellView)
        let height = CloudTreeStyle.compact.rowHeight * Double(percent) / 100
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        cell.removeFromSuperview()
        cell.frame = host.bounds
        host.addSubview(cell)
        readNode.isPinned = pinned
        unreadNode.isPinned = pinned
        let read = try render(cell, node: readNode, fixture: fixture)
        let unread = try render(cell, node: unreadNode, fixture: fixture)
        #if compiler(>=6.2)
        let name = "attention-\(kind)-\(Int(width))-\(percent)-pinned-\(pinned)"
        Attachment.record(try #require(read.representation(using: .png, properties: [:])), named: name + "-read.png")
        Attachment.record(try #require(unread.representation(using: .png, properties: [:])), named: name + "-unread.png")
        #endif
        try expectSeparateIndicator(read: read, unread: unread, in: cell, percent: percent)
        cell.prepareForReuse()
        let cleared = try render(cell, node: readNode, fixture: fixture)
        #expect(cleared.tiffRepresentation == read.tiffRepresentation,
                "A reused cell must remove the dot and restore the compact read layout")
    }

    private func expectSeparateIndicator(
        read: NSBitmapImageRep, unread: NSBitmapImageRep, in cell: CloudTreeCellView, percent: Int
    ) throws {
        #expect(read.pixelsWide == unread.pixelsWide)
        #expect(read.pixelsHigh == unread.pixelsHigh)
        let scale = CGFloat(unread.pixelsWide) / cell.bounds.width
        let readRuns = occupiedRuns(in: read)
        let unreadRuns = occupiedRuns(in: unread)
        let leadingSlot = GlobalFontMagnification.scaledSize(
            CloudTreeStyle.compact.rowGrid.attentionSlot, percent: percent
        )
        let readStart = CGFloat(try #require(readRuns.first?.lowerBound)) / scale
        let unreadDot = try #require(unreadRuns.first)
        let unreadContent = try #require(unreadRuns.dropFirst().first)
        #expect(readStart <= 8, "Read rows keep their compact leading edge: \(readStart)")
        let dotCenter = CGFloat(unreadDot.lowerBound + unreadDot.upperBound) / (2 * scale)
        #expect(abs(dotCenter - leadingSlot / 2) <= 1,
                "The unread dot is centered in the leading slot at every font scale")
        #expect(CGFloat(unreadDot.count) / scale >= 5 && CGFloat(unreadDot.count) / scale <= 7,
                "The unread dot remains six points wide")
        let contentShift = CGFloat(unreadContent.lowerBound) / scale - readStart
        #expect(abs(contentShift - leadingSlot - 2) <= 1,
                "Only unread rows add the leading slot and its gap: \(contentShift)")
        #expect(CGFloat(unreadContent.lowerBound - unreadDot.upperBound) / scale >= 2,
                "The dot stays separate from the pin or icon")
        let dotRows = (0..<unread.pixelsHigh).filter { y in
            unreadDot.contains { x in (unread.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 }
        }
        let top = try #require(dotRows.first)
        let bottom = try #require(dotRows.last) + 1
        #expect(abs(CGFloat(top + bottom - unread.pixelsHigh) / 2) <= scale,
                "The dot stays vertically centered instead of overlapping the icon's upper corner")
        #expect(CGFloat(bottom - top) / scale >= 5 && CGFloat(bottom - top) / scale <= 7,
                "The complete six-point dot remains visible")
    }

    private func occupiedRuns(in bitmap: NSBitmapImageRep) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for x in 0..<bitmap.pixelsWide {
            let occupied = (0..<bitmap.pixelsHigh).contains { y in
                (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2
            }
            if occupied {
                if start == nil { start = x }
            } else if let first = start {
                runs.append(first..<x)
                start = nil
            }
        }
        if let first = start { runs.append(first..<bitmap.pixelsWide) }
        return runs
    }

    @Test("The real outline repaints unread and cleared rows without changing disclosure geometry",
          arguments: [220.0, 380.0])
    func outlineAttentionTransitions(width: Double) throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        fixture.window.setContentSize(NSSize(width: width, height: 560))
        fixture.coordinator.apply(style: .compact)
        fixture.coordinator.apply(nodes: fixture.nodes())
        let outline = try #require(fixture.coordinator.outlineView)
        outline.expandItem(nil, expandChildren: true)
        let rows = CloudTreeNodeBuilder.flattened(fixture.coordinator.nodes).filter {
            $0.structureTag == "workspace" || $0.structureTag == "terminal"
        }
        for pinned in [false, true] {
            if pinned {
                for node in rows { #expect(fixture.coordinator.organize(.pin, nodeID: node.id)) }
            }
            let indexes = try rows.map { node -> Int in
                let row = outline.row(forItem: node)
                try #require(row >= 0)
                return row
            }
            let disclosure = indexes.map { outline.frameOfOutlineCell(atRow: $0) }
            let read = try indexes.map { try captureRow($0, in: outline) }
            fixture.coordinator.apply(nodes: fixture.nodes(unread: ["term_ws_1", "term_ws_2"]))
            try fixture.attachScreenshot(named: "outline-unread-\(Int(width))-pinned-\(pinned)")
            for (index, row) in indexes.enumerated() {
                let unread = try captureRow(row, in: outline)
                let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? CloudTreeCellView)
                try expectSeparateIndicator(read: read[index], unread: unread, in: cell, percent: 100)
                #expect(outline.frameOfOutlineCell(atRow: row) == disclosure[index])
            }
            fixture.coordinator.apply(nodes: fixture.nodes())
            for (index, row) in indexes.enumerated() {
                let cleared = try captureRow(row, in: outline)
                #expect(cleared.tiffRepresentation == read[index].tiffRepresentation)
            }
            try fixture.attachScreenshot(named: "outline-cleared-\(Int(width))-pinned-\(pinned)")
        }
    }

    private func captureRow(_ row: Int, in outline: CloudTreeNSOutlineView) throws -> NSBitmapImageRep {
        let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? CloudTreeCellView)
        cell.setHovered(true)
        cell.layoutSubtreeIfNeeded()
        let bitmap = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
        cell.cacheDisplay(in: cell.bounds, to: bitmap)
        return bitmap
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
        cell.configure(node: node, machineActions: fixture.coordinator.machineActions,
                       nodeActions: fixture.coordinator.nodeActions, style: .compact)
        cell.layoutSubtreeIfNeeded()
        cell.displayIfNeeded()
        let bitmap = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
        cell.cacheDisplay(in: cell.bounds, to: bitmap)
        return bitmap
    }
}
