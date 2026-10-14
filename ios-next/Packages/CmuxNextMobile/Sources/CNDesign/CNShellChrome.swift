#if os(iOS)
public import SwiftUI
public import UIKit

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
/// Status bar content style a root asks the shell for, for example the
/// browser over a light or dark page. Nil follows the app's appearance.
public enum CNStatusBarStyle: String, Hashable, Sendable {
    /// Dark clock and icons, for light content under the status bar.
    case darkContent
    /// Light clock and icons, for dark content under the status bar.
    case lightContent

    /// The style for content whose top edge has `color` (relative luminance).
    public init(over color: UIColor) {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        color.resolvedColor(with: .current).getRed(&r, green: &g, blue: &b, alpha: &a)
        func lin(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        self = luminance > 0.4 ? .darkContent : .lightContent
    }
}

/// Preference a root sets with `.cnStatusBarStyle(_:)`; the shell reads it
/// with `.onCNStatusBarStyleChange` and applies it in its hosting controller.
/// The first non-nil value in the tree wins.
struct CNStatusBarStylePreferenceKey: PreferenceKey {
    static let defaultValue: CNStatusBarStyle? = nil
    static func reduce(value: inout CNStatusBarStyle?, nextValue: () -> CNStatusBarStyle?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// Asks the shell for a status bar style while this view is shown
    /// (nil: follow the appearance).
    public func cnStatusBarStyle(_ style: CNStatusBarStyle?) -> some View {
        preference(key: CNStatusBarStylePreferenceKey.self, value: style)
    }

    /// Shell side: observes the status bar style requested below this view.
    public func onCNStatusBarStyleChange(_ action: @escaping @MainActor @Sendable (CNStatusBarStyle?) -> Void) -> some View {
        onPreferenceChange(CNStatusBarStylePreferenceKey.self) { value in
            MainActor.assumeIsolated { action(value) }
        }
    }

    /// Shell side: hides the status bar requests of a root that is kept alive
    /// but not shown.
    public func cnStatusBarStyleSuppressed(_ suppressed: Bool) -> some View {
        transformPreference(CNStatusBarStylePreferenceKey.self) { if suppressed { $0 = nil } }
    }
}
#endif
