// ui-lab: source Sources/Sidebar/SidebarCompactStatusGlyph.swift
// ui-lab: source Sources/Sidebar/SidebarCompactStatusGlyphView.swift
// ui-lab: shim RenderableSystemSymbol
//
// Every compact status glyph in a mock sidebar laid out with the AppKit
// cell's metrics (SidebarWorkspaceRowTableCellView.layoutContent): 16 pt
// leading, glyph pulled 4 pt into the padding, 12.5 pt semibold titles, plus
// a selected row and group headers.

import AppKit

typealias Glyph = SidebarCompactStatusGlyph

let width: CGFloat = 232
let rowHeight: CGFloat = 31
let outerPad: CGFloat = 6
let leading: CGFloat = 16
let lineCenter: CGFloat = 12.5 * 0.6 + 8

let rows: [(String, Glyph.Kind?, Bool)] = [
    ("needs input", .needsInput, false),
    ("running subagents", .subagents, false),
    ("running", .running, false),
    ("waiting", .waiting, false),
    ("unseen", .unseen, false),
    ("error", .error, false),
    ("starting agent", .pending, false),
    ("open PR", .pullRequest(.open), false),
    ("merged PR", .pullRequest(.merged), false),
    ("closed PR", .pullRequest(.closed), false),
    ("idle agent", .idle, false),
    ("branch only", .branch, false),
    ("plain terminal", .terminal, false),
    ("selected, needs input", .needsInput, true),
    ("selected, merged PR", .pullRequest(.merged), true),
]

let groups: [(String, Glyph.Kind?, Bool)] = [
    ("agents", .needsInput, true),
    ("busy", .running, true),
    ("quiet", nil, false),
]

UILab.main {
    let height = CGFloat(rows.count + groups.count) * rowHeight + 16
    UILab.render(name: "sidebar-compact-status", detail: NSRect(x: 0, y: 0, width: 120, height: CGFloat(rows.count) * rowHeight + 8)) { _ in
        let canvas = UILab.Canvas(frame: NSRect(x: 0, y: 0, width: width, height: height))
        canvas.fill = .windowBackgroundColor

        @MainActor
        func label(_ text: String, size: CGFloat, color: NSColor, x: CGFloat, centerY: CGFloat) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: size, weight: .semibold)
            field.textColor = color
            field.sizeToFit()
            field.frame.origin = NSPoint(x: x, y: centerY - field.frame.height / 2)
            return field
        }

        @MainActor
        func glyphView(_ kind: Glyph.Kind, selected: Bool, x: CGFloat, centerY: CGFloat) -> NSView? {
            let glyph = Glyph(kind: kind, tooltip: "")
            guard glyph.isDrawn else { return nil }
            let view = SidebarCompactStatusGlyphImageView()
            view.configure(glyph, pointSize: 11, color: glyph.color(isActive: selected, selected: .white, secondary: .secondaryLabelColor))
            view.frame = NSRect(x: x, y: centerY - 5.5, width: 11, height: 11)
            return view
        }

        var y: CGFloat = 8
        for (title, kind, selected) in rows {
            let row = UILab.Canvas(frame: NSRect(x: outerPad, y: y, width: width - outerPad * 2, height: rowHeight))
            if selected {
                row.wantsLayer = true
                row.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                row.layer?.cornerRadius = 6
            }
            var x = leading - outerPad
            if let kind, let view = glyphView(kind, selected: selected, x: x - Glyph.leadingPullIn, centerY: lineCenter) {
                row.addSubview(view)
                x += 11 - Glyph.leadingPullIn + Glyph.titleSpacing
            }
            row.addSubview(label(title, size: 12.5, color: selected ? .white : .labelColor, x: x, centerY: lineCenter))
            canvas.addSubview(row)
            y += rowHeight
        }

        // Group headers (SidebarGroupHeaderTableCellView): chevron, folder, name,
        // then the roll-up glyph where the unread count would be.
        for (name, kind, collapsed) in groups {
            let row = UILab.Canvas(frame: NSRect(x: outerPad, y: y, width: width - outerPad * 2, height: rowHeight))
            let mid = rowHeight / 2
            var x: CGFloat = 0
            for (symbol, size, gap) in [(collapsed ? "chevron.right" : "chevron.down", CGFloat(9), CGFloat(4)), ("folder.fill", 11, 6)] {
                let image = NSImageView(image: RenderableSystemSymbol.configuredAppKitImage(systemName: symbol, pointSize: size, weight: .semibold)!)
                image.contentTintColor = .secondaryLabelColor
                image.frame = NSRect(x: x, y: mid - 7, width: 14, height: 14)
                row.addSubview(image)
                x += 14 + gap
            }
            let field = label(name, size: 11, color: .labelColor, x: x, centerY: mid)
            row.addSubview(field)
            if let kind, let view = glyphView(kind, selected: false, x: field.frame.maxX + 6, centerY: mid) {
                row.addSubview(view)
            }
            canvas.addSubview(row)
            y += rowHeight
        }
        return canvas
    }
}
