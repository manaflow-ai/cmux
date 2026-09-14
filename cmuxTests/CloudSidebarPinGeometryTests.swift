import AppKit
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
    @Test("Pin reserves space before content at narrow and wide widths", arguments: [100.0, 320.0])
    func leadingPin(width: Double) throws {
        let unpinned = try contentBounds(width: width, pinned: false)
        let pinned = try contentBounds(width: width, pinned: true)
        #expect(pinned.minX > unpinned.minX + 4, "The pin must precede the identity instead of consuming its trailing edge")
        #expect(abs(pinned.maxX - unpinned.maxX) <= 1, "Trailing alignment must not move when pinning")
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

    private func contentBounds(width: Double, pinned: Bool) throws -> CGRect {
        let host = NSHostingView(rootView: Color.blue
            .modifier(CloudSidebarRowDecoration(isPinned: pinned, showsAttentionSlot: true, hasUnreadNotification: false)))
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
        Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: "pin-\(pinned)-\(Int(width)).png")
        #endif
        return CGRect(x: left, y: 0, width: right - left, height: 28)
    }
}
