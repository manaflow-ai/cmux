import CmuxiOSDesign
import UIKit

/// Resolved colors for one trait collection (CALayer takes CGColor).
struct VignetteColors {
    let window: CGColor
    let border: CGColor
    let dots: CGColor
    let text: CGColor
    let secondary: CGColor
    let success: CGColor
    let waiting: CGColor
    let card: CGColor
    let pill: CGColor
    let ink: CGColor
    let paper: CGColor

    init(traits: UITraitCollection) {
        func resolve(_ color: UIColor) -> CGColor { color.resolvedColor(with: traits).cgColor }
        window = resolve(.secondarySystemBackground)
        border = resolve(.separator)
        dots = resolve(.tertiaryLabel)
        text = resolve(.label)
        secondary = resolve(.secondaryLabel)
        success = resolve(ShellPalette.statusRunning)
        waiting = resolve(ShellPalette.statusWaiting)
        card = resolve(.systemBackground)
        pill = resolve(.tertiarySystemFill)
        ink = resolve(HomePalette.accent)
        paper = resolve(HomePalette.background)
    }
}
