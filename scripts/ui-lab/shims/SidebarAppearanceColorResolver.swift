import AppKit
import SwiftUI

/// ui-lab stand-in for Sources/Sidebar/SidebarAppearanceSupport.swift's
/// resolver: resolves a dynamic color under the given scheme's appearance.
struct SidebarAppearanceColorResolver {
    func resolvedColor(_ color: NSColor, for colorScheme: ColorScheme, opacity: CGFloat? = nil) -> NSColor {
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)!
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB) ?? color
        }
        guard let opacity else { return resolved }
        return resolved.withAlphaComponent(max(0, min(opacity, 1)))
    }
}
