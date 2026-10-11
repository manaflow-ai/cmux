import SwiftUI

extension View {
    /// Shows a loading spinner over this view while `isLoading` is true without
    /// changing its layout size.
    ///
    /// Buttons that swap their label for a `ProgressView` pop their height
    /// because a spinner does not match the label's line height (and inherits
    /// the button's `controlSize`, so it renders oversized). This keeps the
    /// label laid out (just hidden) so the button height stays stable, and
    /// overlays a small spinner that never outgrows the label it replaces.
    ///
    /// - Parameters:
    ///   - isLoading: When true, hide the label and show the spinner.
    ///   - tint: Optional spinner tint (use `.white` on filled/prominent buttons).
    @ViewBuilder
    func mobileButtonLoading(_ isLoading: Bool, tint: Color? = nil) -> some View {
        self
            .opacity(isLoading ? 0 : 1)
            .overlay {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tint)
                }
            }
    }
}
