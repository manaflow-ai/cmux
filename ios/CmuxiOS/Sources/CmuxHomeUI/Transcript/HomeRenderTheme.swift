import CmuxHomeRender
import CmuxiOSDesign
import UIKit

/// The render core's palette from the app's design tokens, resolved for one
/// trait collection (light or dark, Increase Contrast). The sent bubble is
/// the design's ink fill, never a fixed blue.
@MainActor
enum HomeRenderTheme {
    static func palette(for traits: UITraitCollection) -> CmuxHomeRender.HomePalette {
        let theme = CmuxHomeRender.HomePalette.Theme(
            background: color(CmuxiOSDesign.HomePalette.background, traits),
            foreground: color(CmuxiOSDesign.HomePalette.primaryText, traits),
            accent: color(CmuxiOSDesign.HomePalette.outgoingBubble, traits),
            failure: color(CmuxiOSDesign.HomePalette.failure, traits))
        return CmuxHomeRender.HomePalette.themed(theme, active: true)
    }

    /// An opaque sRGB colour (extended components clamped to 0...1).
    private static func color(_ dynamic: UIColor, _ traits: UITraitCollection) -> HomeColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let resolved = dynamic.resolvedColor(with: traits)
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return HomeColor(red: 0.5, green: 0.5, blue: 0.5) }
        func clamp(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }
        return HomeColor(red: clamp(r), green: clamp(g), blue: clamp(b))
    }
}
