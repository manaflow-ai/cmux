import SwiftUI

/// Dynamic Type for the browser chrome, the way Safari scales it: the text
/// follows the user's size up to a cap per surface, because the controls
/// around it (the 48 pt toolbar, the 250 pt menu, grid cards) keep their size.
struct ChromeType: Equatable {
    /// Toolbar and grid controls: the capsule keeps its height.
    static let barCap: DynamicTypeSize = .xxxLarge
    /// Grid card titles: one line on a narrow card.
    static let cardCap: DynamicTypeSize = .xxLarge
    /// Menus and the start page: rows grow, up to the first accessibility size.
    static let pageCap: DynamicTypeSize = .accessibility1

    var size: DynamicTypeSize
    var cap: DynamicTypeSize

    /// The size the text is drawn at: the user's, but no larger than the cap.
    var effective: DynamicTypeSize { min(size, cap) }
}

#if os(iOS)
import UIKit

extension ChromeType {
    /// `base` points at the Large (default) size, scaled like body text.
    func scaled(_ base: CGFloat) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(effective))
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: base, compatibleWith: traits)
    }
}

/// `.font(.system(size:weight:))` that follows Dynamic Type up to `cap`.
struct ChromeFont: ViewModifier {
    var size: CGFloat
    var weight: Font.Weight = .regular
    var cap: DynamicTypeSize
    @Environment(\.dynamicTypeSize) private var dynamicType

    func body(content: Content) -> some View {
        content.font(.system(size: ChromeType(size: dynamicType, cap: cap).scaled(size), weight: weight))
    }
}

extension View {
    func chromeFont(_ size: CGFloat, weight: Font.Weight = .regular, cap: DynamicTypeSize = ChromeType.barCap) -> some View {
        modifier(ChromeFont(size: size, weight: weight, cap: cap))
    }
}
#endif
