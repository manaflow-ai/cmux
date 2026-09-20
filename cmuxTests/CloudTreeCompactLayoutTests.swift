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
    @Test("Machine spacing matches leaf rows while narrow rows retain accessible identities",
          arguments: [220.0, 380.0], [75, 100, 150, 200])
    func iconLabelSpacing(width: Double, percent: Int) throws {
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
        let template = try #require(fixture.nodes(titles: ["workspace-1"]).first)
        let machine = MachineSnapshot(
            id: fixture.machine.rawValue, provider: "fixture", image: "fixture", isDesktop: false,
            activity: .ready, createdAt: nil, label: "early-plum-alpaca"
        )
        let root = CloudTreeNode(id: template.id, kind: .machine(machine, nil), children: template.children)
        fixture.coordinator.apply(nodes: [root])
        let outline = try #require(fixture.coordinator.outlineView)
        outline.expandItem(nil, expandChildren: true)
        let folder = try #require(root.children.first { $0.structureTag == "workspacesGroup" }?.children.first)
        let terminal = try #require(folder.children.first { $0.structureTag == "terminal" })
        let rows = [root, folder, terminal]
        let scale = CGFloat(percent) / 100
        // Ink edges are sampled in whole backing pixels. Round the allowance
        // to that grid, rather than rejecting a 2px delta against 1.875px.
        let pixelsPerPoint = fixture.window.backingScaleFactor
        let tolerance = (1.25 * scale * pixelsPerPoint).rounded() / pixelsPerPoint

        for pinned in [false, true] {
            for node in rows { node.isPinned = pinned }
            outline.reloadData()
            fixture.container.layoutSubtreeIfNeeded()
            try fixture.attachScreenshot(named: "icon-spacing-\(Int(width))-\(percent)-pinned-\(pinned)")
            let cells = try rows.map { node in
                let row = outline.row(forItem: node)
                let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true))
                #expect(cell.accessibilityLabel()?.contains(node.searchableTitle) == true)
                return cell
            }
            if width == 220, percent == 200 {
                // The unchanged leaf rows cannot fit title ink at this width
                // and zoom, even before #13072. Capture the clipping and check
                // full accessible identities; there is no visible gap to measure.
                #if compiler(>=6.2)
                Attachment.record("Leaf titles are clipped at 220pt/200%; spacing is not measurable. Accessible identities checked.",
                                  named: "icon-spacing-220-200-pinned-\(pinned).txt")
                #endif
                continue
            }
            let gaps = try cells.map { try iconLabelGap(in: $0, pinned: pinned) }
            #expect(abs(gaps[0] - gaps[1]) <= tolerance,
                    "Machine and folder glyph side bearings may differ slightly, not their spacing: \(gaps)")
            #expect(abs(gaps[0] - gaps[2]) <= tolerance,
                    "Machine and terminal must have comparable visible gaps: \(gaps)")
            #if compiler(>=6.2)
            Attachment.record("machine/folder/terminal gaps in points: \(gaps)",
                              named: "icon-spacing-\(Int(width))-\(percent)-pinned-\(pinned).txt")
            #endif
        }
    }

    @Test("Cloud, locked, local and pending machine titles share the folder icon column",
          arguments: CloudTreeStyle.presets, [75, 100, 150, 200])
    func machineVariants(style: CloudTreeStyle, percent: Int) throws {
        let oldPercent = UserDefaults.standard.object(forKey: GlobalFontMagnification.percentKey)
        UserDefaults.standard.set(percent, forKey: GlobalFontMagnification.percentKey)
        defer {
            if let oldPercent { UserDefaults.standard.set(oldPercent, forKey: GlobalFontMagnification.percentKey) }
            else { UserDefaults.standard.removeObject(forKey: GlobalFontMagnification.percentKey) }
        }
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        fixture.window.setContentSize(NSSize(width: 380, height: 620))
        fixture.coordinator.apply(style: style)
        let title = "early-plum-alpaca"
        let machine = MachineSnapshot(
            id: "fixture", provider: "fixture", image: "fixture", isDesktop: false,
            activity: .ready, createdAt: nil, label: title
        )
        var locked = machine
        locked.freeAccess = .expired
        let pending = MachineCreateOperation(
            id: UUID(), request: MachineCreateCoordinatorTests.newMachineRequest(name: title),
            startedAt: Date(timeIntervalSince1970: 0), phase: .failed(output: "fixture")
        )
        let kinds: [CloudTreeNode.Kind] = [
            .localWorkspace(CloudTreeLocalWorkspaceRow(workspaceID: UUID(), title: title, terminalCount: 0, isSelected: true)),
            .machine(machine, nil), .machine(locked, nil),
            .localMachine(CloudTreeLocalMachineRow(name: title, terminalCount: 0, browserCount: 0)),
            .pendingMachine(pending)
        ]
        let nodes = kinds.enumerated().map { CloudTreeNode(id: "variant-\($0.offset)", kind: $0.element) }
        fixture.coordinator.apply(nodes: nodes)
        fixture.container.layoutSubtreeIfNeeded()
        try fixture.attachScreenshot(named: "machine-icon-variants-\(style.id)-\(percent)")
        let outline = try #require(fixture.coordinator.outlineView)
        let starts = try nodes.map { node in
            let cell = try #require(outline.view(atColumn: 0, row: outline.row(forItem: node), makeIfNecessary: true))
            let ink = try inkColumns(in: cell)
            try #require(ink.runs.count >= 2)
            return CGFloat(ink.runs[1].lowerBound) / ink.scale
        }
        // Sections insets the whole machine identity 6pt inside its band.
        // Preserve that decoration while comparing the shared icon column.
        let bandInset: CGFloat = style.machineBand ? 6 : 0
        for start in starts.dropFirst() {
            #expect(abs(start - starts[0] - bandInset) <= CGFloat(percent) / 100,
                    "Every machine state reserves the same title column as a folder: \(starts)")
        }
    }

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
        // AppKit reports AXUnknown for this internal button on macOS 15.
        // Verify its actual pointer target and action instead of that metadata.
        let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let hit = try #require(outline.cmuxHitTest(windowPoint: center))
        #expect(hit === button || hit.isDescendant(of: button))
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

    /// Measure the actual empty columns between glyph ink and title ink, not
    /// the layout constants: SF Symbol side bearings and scaling matter here.
    private func iconLabelGap(in view: NSView, pinned: Bool) throws -> CGFloat {
        let ink = try inkColumns(in: view)
        let icon = pinned ? 1 : 0
        try #require(ink.runs.count > icon + 1, "Expected visible icon and title ink")
        return CGFloat(ink.runs[icon + 1].lowerBound - ink.runs[icon].upperBound) / ink.scale
    }

    private func inkColumns(in view: NSView) throws -> (runs: [Range<Int>], scale: CGFloat) {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
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
        return (runs, scale)
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
