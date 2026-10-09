#if os(iOS)
public import SwiftUI

/// App-level chrome that the active shell injects into every module root.
///
/// The drawer shell sets `cnLeadingBarItem` to its hamburger button; the tab
/// shell leaves it nil. A module root shows it as the leading toolbar item of
/// its top-level screen with `.cnShellLeadingBarItem()` (or by reading
/// `@Environment(\.cnLeadingBarItem)` itself).
extension EnvironmentValues {
    /// Leading toolbar item supplied by the shell (the drawer's hamburger).
    @Entry public var cnLeadingBarItem: AnyView? = nil
    /// True while the drawer shell's sidebar is open or being dragged. Roots
    /// can use it to pause expensive work or resign first responder.
    @Entry public var cnDrawerIsOpen: Bool = false
}

/// Adds the shell's leading bar item (if any) to the toolbar of the view it is
/// applied to. Apply it to the root screen inside a `NavigationStack`.
public struct CNShellLeadingBarItemModifier: ViewModifier {
    @Environment(\.cnLeadingBarItem) private var item

    public init() {}

    public func body(content: Content) -> some View {
        content.toolbar {
            if let item {
                ToolbarItem(placement: .topBarLeading) { item }
            }
        }
    }
}

extension View {
    /// Shows the shell-injected leading toolbar item (the drawer hamburger).
    public func cnShellLeadingBarItem() -> some View {
        modifier(CNShellLeadingBarItemModifier())
    }
}
#endif
