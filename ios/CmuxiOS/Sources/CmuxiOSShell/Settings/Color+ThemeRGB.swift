import CmuxTheme
import SwiftUI

extension Color {
    /// An opaque color from a theme color.
    init(_ rgb: ThemeRGB) {
        self.init(red: Double(rgb.red), green: Double(rgb.green), blue: Double(rgb.blue))
    }
}
