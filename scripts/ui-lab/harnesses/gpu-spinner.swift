// ui-lab: source Sources/Sidebar/GPUSpinnerStyle.swift
// ui-lab: source Sources/Sidebar/GPUSpinnerNSView.swift
// ui-lab: shim SidebarAppearanceColorResolver
//
// The sidebar loading spinner in each style, at the sizes rows use (12 pt,
// 16 pt). A still frame: the rotation is a Core Animation loop that ui-lab
// does not advance.

import AppKit

UILab.main {
    let styles: [GPUSpinnerStyle] = [.macOSSpokes, .arc]
    let sizes: [CGFloat] = [12, 16]
    let cell: CGFloat = 28
    let bounds = NSRect(x: 0, y: 0, width: cell * CGFloat(sizes.count) + 16, height: cell * CGFloat(styles.count) + 16)
    UILab.render(name: "gpu-spinner", detail: bounds) { scheme in
        let canvas = UILab.Canvas(frame: bounds)
        canvas.fill = .windowBackgroundColor
        for (row, style) in styles.enumerated() {
            for (column, size) in sizes.enumerated() {
                let spinner = GPUSpinnerNSView(frame: NSRect(
                    x: 8 + CGFloat(column) * cell + (cell - size) / 2,
                    y: 8 + CGFloat(row) * cell + (cell - size) / 2,
                    width: size,
                    height: size
                ))
                spinner.style = style
                // The spinner colors itself from this, not the appearance.
                spinner.colorScheme = scheme
                canvas.addSubview(spinner)
            }
        }
        return canvas
    }
}
