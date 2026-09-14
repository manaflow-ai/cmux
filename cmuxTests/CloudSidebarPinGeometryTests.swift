import AppKit
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
    @Test("Pin reserves space before content at narrow and wide widths", arguments: [100.0, 320.0], [75, 100, 150, 200])
    func leadingPin(width: Double, percent: Int) throws {
        let unpinned = try contentBounds(width: width, pinned: false, percent: percent)
        let pinned = try contentBounds(width: width, pinned: true, percent: percent)
        #expect(pinned.minX > unpinned.minX + 4, "The pin must precede the identity instead of consuming its trailing edge")
        #expect(abs(pinned.maxX - unpinned.maxX) <= 1, "Trailing alignment must not move when pinning")
    }

    @Test("Pin geometry follows the same magnification as row text")
    func pinMagnification() throws {
        let small = try contentBounds(width: 140, pinned: true, percent: 75)
        let large = try contentBounds(width: 140, pinned: true, percent: 200)
        #expect(large.minX > small.minX + 4)
        #expect(abs(large.maxX - small.maxX) <= 1)
    }

    @Test("Narrow pinned folders retain the full accessible title and selection")
    func longFolderTitle() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let title = "workspace-with-a-long-name-that-must-truncate-visually"
        fixture.window.setContentSize(NSSize(width: 220, height: 560))
        fixture.coordinator.apply(nodes: fixture.nodes(titles: [title, "workspace-2"]))
        #expect(fixture.coordinator.organize(.pin, nodeID: fixture.folderID("ws_1")))
        let outline = try #require(fixture.coordinator.outlineView)
        let folder = try #require(CloudTreeNodeBuilder.flattened(fixture.coordinator.nodes).first { $0.id == fixture.folderID("ws_1") })
        let row = outline.row(forItem: folder)
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? CloudTreeCellView)
        #expect(cell.accessibilityLabel() == title)
        #expect(folder.isPinned)
        #expect(outline.selectedRow == row)
        try fixture.attachScreenshot(named: "pinned-long-folder-narrow-selected")
        outline.deselectAll(nil)
        try fixture.attachScreenshot(named: "pinned-long-folder-narrow-unselected")
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

    private func contentBounds(width: Double, pinned: Bool, percent: Int) throws -> CGRect {
        let host = NSHostingView(rootView: Color.blue
            .modifier(CloudSidebarRowDecoration(isPinned: pinned, showsAttentionSlot: true, hasUnreadNotification: false))
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
            if color.blueComponent > color.redComponent + 0.3 { xs.append(x) }
        }
        let scale = Double(bitmap.pixelsWide) / width
        let left = Double(try #require(xs.min())) / scale
        let right = Double(try #require(xs.max())) / scale
        #if compiler(>=6.2)
        Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: "pin-\(pinned)-\(Int(width))-\(percent).png")
        #endif
        return CGRect(x: left, y: 0, width: right - left, height: 28)
    }
}
