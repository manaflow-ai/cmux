public import CmuxiOSFeatureKit
public import Foundation

/// One in-app destination. Every entry point (URL scheme, universal link,
/// notification tap) produces a route; `ShellRouter` delivers it.
public enum ShellRoute: Hashable, Sendable {
    case home
    case feed(item: String?)
    case workspaces
    case workspace(host: HostID, workspace: String, surface: String?)
    case compose(host: HostID?, workspace: String?)
    case hosts
    case settings
    case diagnostics
    case whatsNew
    /// Universal search (lane C15), optionally with text typed.
    case search(query: String?)
    /// A `pair` or `attach` link, passed whole to the pairing lane (B6),
    /// which owns that grammar.
    case pairing(URL)

    /// Routes that need a signed-in account wait (deferred) until one is.
    public var requiresAccount: Bool {
        switch self {
        case .diagnostics: false
        default: true
        }
    }

    /// Routes the signed-out guest shell can open (Hosts, Settings and
    /// screens that need no account), e5-extras.md section 5.
    public var allowsGuest: Bool {
        switch self {
        case .hosts, .settings, .diagnostics, .whatsNew: true
        default: false
        }
    }
}
