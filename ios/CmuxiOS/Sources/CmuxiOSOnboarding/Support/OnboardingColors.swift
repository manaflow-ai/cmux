import CmuxiOSDesign
import SwiftUI

/// Ink and grays only (no blue): the primary button is ink on paper,
/// inverted in dark mode; status glyphs use the muted system green.
enum OnboardingColors {
    static let ink = Color(uiColor: HomePalette.accent)
    static let paper = Color(uiColor: HomePalette.background)
    static let primaryText = Color(uiColor: HomePalette.primaryText)
    static let secondaryText = Color(uiColor: HomePalette.secondaryText)
    static let tertiaryText = Color(uiColor: HomePalette.tertiaryText)
    static let surface = Color(uiColor: .secondarySystemBackground)
    static let raisedSurface = Color(uiColor: .tertiarySystemBackground)
    static let fill = Color(uiColor: .tertiarySystemFill)
    static let track = Color(uiColor: .quaternarySystemFill)
    static let success = Color(uiColor: ShellPalette.statusRunning)
    static let waiting = Color(uiColor: ShellPalette.statusWaiting)
    static let outgoingBubble = Color(uiColor: HomePalette.outgoingBubble)
    static let outgoingText = Color(uiColor: HomePalette.outgoingText)
    static let incomingBubble = Color(uiColor: HomePalette.incomingBubble)
}
