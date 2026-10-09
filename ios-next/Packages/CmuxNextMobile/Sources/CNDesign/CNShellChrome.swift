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
    /// Item the shell asks the root to show (a row tapped in the drawer
    /// sidebar, or the compose button). Roots that can open the item observe
    /// it with `.onChange(of:)`; the `nonce` makes repeated taps distinct.
    @Entry public var cnShellRoute: CNShellRoute? = nil
    /// Terminal font size from Settings, in points.
    @Entry public var cnTerminalFontSize: CGFloat = 13
    /// True when the root is hosted in the tab shell's `TabView`. Roots keep
    /// their own floating bottom chrome above the tab bar (safe area) and
    /// may hide the tab bar on pushed detail screens, as Messages does.
    @Entry public var cnHostedInTabBar: Bool = false
}

/// A request from the shell to open one item inside a module root.
public struct CNShellRoute: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// `id` is a conversation id (Home).
        case conversation
        /// Start a new Chief conversation / compose (Home).
        case compose
        /// `id` is an agent session id.
        case agentSession
        /// `id` is a terminal id.
        case terminal
        /// `id` is a browser tab id.
        case browserTab
    }

    public var kind: Kind
    public var id: String?
    public var nonce: UUID

    public init(kind: Kind, id: String? = nil, nonce: UUID = UUID()) {
        self.kind = kind; self.id = id; self.nonce = nonce
    }
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
