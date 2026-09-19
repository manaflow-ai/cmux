import AppKit
import CmuxFoundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Compact Cloud outline", .serialized)
struct CloudTreeCompactLayoutTests {
    @Test("Folders start as close to their carets as plain section headings",
          arguments: [220.0, 360.0], [100, 150])
    func compactRows(width: Double, percent: Int) throws {
        let oldPercent = UserDefaults.standard.object(forKey: GlobalFontMagnification.percentKey)
        UserDefaults.standard.set(percent, forKey: GlobalFontMagnification.percentKey)
        defer {
            if let oldPercent { UserDefaults.standard.set(oldPercent, forKey: GlobalFontMagnification.percentKey) }
            else { UserDefaults.standard.removeObject(forKey: GlobalFontMagnification.percentKey) }
        }
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        fixture.window.setContentSize(NSSize(width: width, height: 620))
        fixture.coordinator.apply(style: .compact)
        fixture.coordinator.apply(nodes: fixture.nodes(titles: ["workspace-with-a-long-name", "workspace-2"]))
        let outline = try #require(fixture.coordinator.outlineView)
        let nodes = CloudTreeNodeBuilder.flattened(fixture.coordinator.nodes)
        let folder = try #require(nodes.first { $0.id == fixture.folderID("ws_1") })
        let section = try #require(nodes.first { $0.structureTag == "workspacesGroup" })
        fixture.container.layoutSubtreeIfNeeded()
        let scale = Double(percent) / 100
        let folderGap = try leadingGap(folder, in: outline)
        let sectionGap = try leadingGap(section, in: outline)
        #expect(abs(folderGap - sectionGap) <= 4 * scale,
                "Folder and header use the same close spacing, allowing glyph side bearings: \(folderGap), \(sectionGap)")
        #expect(folderGap <= 6 * scale, "No reserved unread column between caret and folder")
        for row in 0..<outline.numberOfRows {
            #expect(abs(outline.rect(ofRow: row).height - 22 * scale) <= 0.5)
        }
        try fixture.attachScreenshot(named: "compact-tree-\(Int(width))-\(percent)")

        let row = outline.row(forItem: folder)
        let before = outline.frameOfOutlineCell(atRow: row)
        let button = try #require(descendants(of: outline).compactMap { $0 as? NSButton }.first {
            $0.identifier == NSOutlineView.disclosureButtonIdentifier && outline.row(for: $0) == row
        })
        // The native disclosure control draws the caret: no custom artwork.
        #expect(String(describing: type(of: button)) != "CloudTreeDisclosureButton")
        #expect(button.accessibilityRole() == .disclosureTriangle)
        #expect(outline.isItemExpanded(folder))
        button.performClick(nil)
        #expect(!outline.isItemExpanded(folder), "Keep the native disclosure action")
        fixture.container.layoutSubtreeIfNeeded()
        let after = outline.frameOfOutlineCell(atRow: row)
        #expect(before.size == after.size, "Collapsing must not resize the caret column")
        #expect(abs(after.width - CloudTreeRowGrid.disclosureSlot * scale) <= 0.5)
        try fixture.attachScreenshot(named: "compact-tree-collapsed-\(Int(width))-\(percent)")
        let reopenedButton = try #require(descendants(of: outline).compactMap { $0 as? NSButton }.first {
            $0.identifier == NSOutlineView.disclosureButtonIdentifier && outline.row(for: $0) == row
        })
        reopenedButton.performClick(nil)
        #expect(outline.isItemExpanded(folder))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func leadingGap(_ node: CloudTreeNode, in outline: CloudTreeNSOutlineView) throws -> CGFloat {
        let row = outline.row(forItem: node)
        let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        let pixels = try ink(in: cell)
        let content = outline.frameOfCell(atColumn: 0, row: row)
        return content.minX + pixels.bounds.minX - outline.frameOfOutlineCell(atRow: row).maxX
    }

    private func ink(in view: NSView) throws -> (bounds: CGRect, area: CGFloat) {
        view.needsDisplay = true
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        var rect = CGRect.null
        var area: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let alpha = try #require(bitmap.colorAt(x: x, y: y)?.alphaComponent)
                if alpha > 0.2 { rect = rect.union(CGRect(x: x, y: y, width: 1, height: 1)) }
                area += alpha
            }
        }
        try #require(!rect.isNull)
        return (CGRect(x: rect.minX / scale, y: rect.minY / scale, width: rect.width / scale, height: rect.height / scale),
                area / (scale * scale))
    }
}
