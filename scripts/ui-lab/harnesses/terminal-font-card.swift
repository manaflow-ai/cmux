// ui-lab: source Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/GhosttyTerminalOptions/GhosttyCellHeightAdjustment.swift
// ui-lab: source Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Models/NSFont+TerminalFamily.swift
// ui-lab: source Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/TerminalFontPreview.swift
// ui-lab: source Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Sections/TerminalFontFamilyPicker.swift
// ui-lab: shim CmuxFont

import AppKit
import SwiftUI

// Settings > Terminal Font card pieces: the preview at a few font, size and
// line-height choices, and the font picker popover (340 x 400 in the app).
UILab.main {
    let previewBounds = NSRect(x: 0, y: 0, width: 560, height: 150)
    let previews: [(String, String?, Double, GhosttyCellHeightAdjustment)] = [
        ("default", nil, 13, .unadjusted),
        ("menlo-14-plus10", "Menlo", 14, .percent(10)),
        ("courier-new-16", "Courier New", 16, .unadjusted),
    ]
    for (name, family, size, cellHeight) in previews {
        UILab.render(name: "preview-\(name)") { _ in
            let canvas = UILab.Canvas(frame: previewBounds)
            canvas.fill = .windowBackgroundColor
            let host = NSHostingView(rootView: TerminalFontPreview(family: family, size: size, cellHeight: cellHeight).padding(12))
            host.frame = previewBounds
            canvas.addSubview(host)
            return canvas
        }
    }

    let pickerBounds = NSRect(x: 0, y: 0, width: 340, height: 400)
    UILab.render(name: "picker") { _ in
        let canvas = UILab.Canvas(frame: pickerBounds)
        canvas.fill = .windowBackgroundColor
        let families = ["Andale Mono", "Courier New", "Menlo", "Monaco", "PT Mono", "SF Mono"]
        let picker = TerminalFontFamilyPicker(
            families: families,
            selection: "Menlo",
            hoveredFamily: .constant(.some("Monaco"))
        ) { _ in }
        let host = NSHostingView(rootView: picker)
        host.frame = pickerBounds
        canvas.addSubview(host)
        return canvas
    }
}
