#if os(iOS)
public import SwiftUI
import CNDesign
import UIKit

/// Grouped-form colors on the cmux-next palette: in dark the page is the
/// CNDesign background (#1E1E1E, not the system's black) with elevated rows;
/// light keeps the system grouped colors.
extension View {
    /// Page background of a grouped `Form`.
    public func cnGroupedFormBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Color(uiColor: CNGroupedColors.page).ignoresSafeArea())
    }

    /// Row background for the rows of a grouped `Form` (apply to its content).
    public func cnGroupedRowBackground() -> some View {
        listRowBackground(Color(uiColor: CNGroupedColors.row))
    }
}

enum CNGroupedColors {
    static let page = UIColor { traits in
        traits.userInterfaceStyle == .dark ? CNTheme.shared.palette.background : .systemGroupedBackground
    }
    static let row = UIColor { traits in
        traits.userInterfaceStyle == .dark ? CNTheme.shared.palette.elevated : .secondarySystemGroupedBackground
    }
}
#endif
