import AppKit
import CmuxAppKitSupportUI
import CmuxCloud
import CmuxFoundation
import CmuxSurfaceCatalogModel
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// #16189: Cloud Machines and My Devices each name their kind once, with a
/// glyph at the leading edge of the header, and the machine and device rows
/// under them repeat no icon. Rows keep their names, status and controls.
@MainActor
@Suite("Cloud sidebar: section identity icons")
struct CloudSidebarSectionIdentityIconTests {
    @Test("Headers lead with one glyph; machine and device rows draw none", arguments: [220.0, 380.0])
    func headersCarryTheOnlyIdentityGlyph(width: Double) throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let tree = try CloudTreeHeaderActionsTests.Tree(
            fixture: fixture, width: width,
            machines: [CloudTreeHeaderActionsTests.fleetRow("brave-otter"), CloudTreeHeaderActionsTests.fleetRow("calm-heron")],
            devices: CloudTreeHeaderActionsTests.onlineMacs(2),
            canCreateCloudMachine: true
        )
        try fixture.attachScreenshot(named: "section-identity-icons-\(Int(width))")

        for header in [tree.cloudSection, tree.devicesSection] {
            let cell = try tree.cell(for: header)
            let display = try CloudTreeHeaderActionsTests.display(in: cell)
            let icons = Self.icons(in: display)
            #expect(icons.count == 1, "\(header.id) shows exactly one identity glyph")
            let icon = try #require(icons.first)
            let iconFrame = icon.convert(icon.bounds, to: display)
            let ink = try Self.inkRuns(in: display)
            // The glyph is the leading ink; the title follows it.
            let first = try #require(ink.first)
            #expect(first.lowerBound <= iconFrame.maxX && first.upperBound >= iconFrame.minX,
                    "\(header.id)'s glyph is its leading ink: \(ink) vs \(iconFrame)")
            #expect(ink.contains { $0.lowerBound >= iconFrame.maxX }, "\(header.id)'s title follows the glyph")
            // The header's name is unchanged for assistive technology.
            #expect(cell.accessibilityLabel()?.hasPrefix(header.searchableTitle) == true)
        }

        let machines = tree.cloudSection.children.filter(\.isMachineRow)
        let devices = tree.devicesSection.children.filter { if case .device = $0.kind { true } else { false } }
        #expect(machines.count == 2 && devices.count == 2)
        for row in machines + devices {
            let cell = try tree.cell(for: row)
            let display = try CloudTreeHeaderActionsTests.display(in: cell)
            #expect(Self.icons(in: display).isEmpty, "\(row.id) no longer repeats its section's glyph")
            #expect(cell.accessibilityLabel()?.contains(row.searchableTitle) == true, "\(row.id) keeps its identity")
        }
    }

    /// The name, not an icon, now starts every live machine row, so the list
    /// does not jump as a create finishes or a free-plan machine locks. A
    /// failed create has no machine identity, so its warning starts the row
    /// directly beside the error instead of repeating the request label.
    @Test("Machine states keep identity columns and failed creates show only the error",
          arguments: CloudTreeStyle.presets, [100, 150])
    func machineNamesShareOneColumn(style: CloudTreeStyle, percent: Int) throws {
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
        let ready = MachineSnapshot(
            id: "fixture", provider: "fixture", image: "fixture", isDesktop: false,
            activity: .ready, createdAt: nil, label: title
        )
        var locked = ready
        locked.freeAccess = .expired
        let request = MachineCreateCoordinatorTests.newMachineRequest(name: title)
        let creating = MachineCreateOperation(id: UUID(), request: request, startedAt: Date(timeIntervalSince1970: 0))
        let failed = MachineCreateOperation(
            id: UUID(), request: request, startedAt: Date(timeIntervalSince1970: 0), phase: .failed(output: "fixture")
        )
        let kinds: [CloudTreeNode.Kind] = [
            .machine(ready, nil), .machine(locked, nil), .pendingMachine(creating), .pendingMachine(failed)
        ]
        let nodes = kinds.enumerated().map { CloudTreeNode(id: "machine-state-\($0.offset)", kind: $0.element) }
        fixture.coordinator.apply(nodes: nodes)
        fixture.container.layoutSubtreeIfNeeded()
        try fixture.attachScreenshot(named: "machine-name-column-\(style.id)-\(percent)")
        let outline = try #require(fixture.coordinator.outlineView)

        var starts: [CGFloat] = []
        var glyphCounts: [Int] = []
        for (index, node) in nodes.enumerated() {
            let cell = try #require(
                outline.view(atColumn: 0, row: outline.row(forItem: node), makeIfNecessary: true) as? CloudTreeCellView
            )
            cell.layoutSubtreeIfNeeded()
            let ink = try Self.inkRuns(in: cell)
            let titleStart = try #require(ink.first).lowerBound
            // A status glyph (lock, warning) is never the leading ink.
            let glyphs = Self.icons(in: try CloudTreeHeaderActionsTests.display(in: cell))
            for glyph in glyphs {
                let glyphFrame = glyph.convert(glyph.bounds, to: cell)
                if index < 3 {
                    #expect(glyphFrame.minX > titleStart, "\(node.id)'s status glyph follows its name")
                } else {
                    #expect(glyphFrame.minX <= titleStart + 1, "\(node.id)'s warning leads the error")
                }
            }
            glyphCounts.append(glyphs.count)
            starts.append(titleStart)
        }
        // Ready: nothing; locked: its lock; creating: a spinner, not a glyph; failed: its warning.
        #expect(glyphCounts == [0, 1, 0, 1], "Status glyphs survive the icon removal: \(glyphCounts)")
        let pixelsPerPoint = fixture.window.backingScaleFactor
        let tolerance = (CGFloat(percent) / 100 * pixelsPerPoint).rounded() / pixelsPerPoint
        // Only live rows have a name column. The failed row deliberately starts
        // with its warning icon and error text.
        for start in starts.dropFirst().prefix(2) {
            #expect(abs(start - starts[0]) <= tolerance, "Every machine state starts its name on one column: \(starts)")
        }
    }

    static func icons(in view: NSView) -> [CmuxResolvedIconImageView] {
        view.subviews.flatMap { subview -> [CmuxResolvedIconImageView] in
            if let icon = subview as? CmuxResolvedIconImageView, !icon.isHidden, icon.bounds.width > 0 { return [icon] }
            return icons(in: subview)
        }
    }

    /// Columns (in points, in `view`'s coordinates) that hold visible ink,
    /// merged into runs, leading first.
    static func inkRuns(in view: NSView) throws -> [ClosedRange<CGFloat>] {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / max(1, view.bounds.width)
        var runs: [ClosedRange<CGFloat>] = []
        var start: Int?
        for x in 0...bitmap.pixelsWide {
            let occupied = x < bitmap.pixelsWide && (0..<bitmap.pixelsHigh).contains { y in
                (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2
            }
            if occupied, start == nil {
                start = x
            } else if !occupied, let first = start {
                runs.append(CGFloat(first) / scale...CGFloat(x) / scale)
                start = nil
            }
        }
        return runs
    }
}
