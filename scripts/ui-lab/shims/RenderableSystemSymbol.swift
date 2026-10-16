import AppKit
import SwiftUI

/// ui-lab stand-in for Sources/RenderableSystemSymbol.swift's AppKit path:
/// the same symbol configuration (point size, weight, monochrome, template),
/// without the app's caches and font-magnification plumbing.
enum RenderableSystemSymbol {
    @MainActor
    static func configuredAppKitImage(systemName: String, pointSize: CGFloat, weight: Font.Weight? = nil) -> NSImage? {
        guard let base = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) else { return nil }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: nsWeight(weight))
            .applying(.preferringMonochrome())
        let image = base.withSymbolConfiguration(configuration) ?? base
        image.isTemplate = true
        return image
    }

    private static func nsWeight(_ weight: Font.Weight?) -> NSFont.Weight {
        switch weight {
        case .ultraLight?: return .ultraLight
        case .thin?: return .thin
        case .light?: return .light
        case .medium?: return .medium
        case .semibold?: return .semibold
        case .bold?: return .bold
        case .heavy?: return .heavy
        case .black?: return .black
        default: return .regular
        }
    }
}
