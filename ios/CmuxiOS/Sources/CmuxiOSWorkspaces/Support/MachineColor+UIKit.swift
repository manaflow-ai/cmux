import CmuxiOSWorkspacesCore
import UIKit

extension MachineColor {
    /// Muted system hues, used only on small glyphs and bars.
    var uiColor: UIColor {
        switch self {
        case .graphite: .systemGray
        case .green: .systemGreen
        case .orange: .systemOrange
        case .red: .systemRed
        case .purple: .systemPurple
        case .teal: .systemTeal
        case .brown: .systemBrown
        case .pink: .systemPink
        case .yellow: .systemYellow
        }
    }
}
