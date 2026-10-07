import UIKit

/// The workspace look the Mac stores: palette tokens (CmuxNextDesign
/// `GroupColor`) or `#RRGGBB`, and SF Symbol icons.
struct WorkspaceLook {
    static let palette = ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]
    static let icons = [
        "terminal", "hammer", "wrench.and.screwdriver", "server.rack", "globe", "doc.text", "book", "flask",
        "cpu", "network", "shippingbox", "cloud", "lock", "star", "flame", "bolt", "leaf", "paintbrush",
        "chart.bar", "gearshape",
    ]

    /// The color for a token or `#RRGGBB`; nil when unset or unknown.
    static func color(_ value: String?) -> UIColor? {
        guard let value else { return nil }
        switch value {
        case "grey": return .systemGray
        case "blue": return .systemBlue
        case "red": return .systemRed
        case "yellow": return .systemYellow
        case "green": return .systemGreen
        case "pink": return .systemPink
        case "purple": return .systemPurple
        case "cyan": return .systemCyan
        case "orange": return .systemOrange
        default: break
        }
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : ""
        guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return nil }
        return UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
