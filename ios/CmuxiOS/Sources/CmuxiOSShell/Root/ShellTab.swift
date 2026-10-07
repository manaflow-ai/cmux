import Foundation

/// The root destinations, in tab order. Home is always first and Settings
/// always last; the feature tabs are behind feature flags until their
/// lanes ship.
public enum ShellTab: String, CaseIterable, Hashable, Sendable {
    case home
    case feed
    case workspaces
    case compose
    case hosts
    case search
    case settings

    /// The flag that shows this tab; nil for tabs that always show.
    public var flag: ShellFeatureFlag? {
        switch self {
        case .home, .settings: nil
        case .feed: .feedTab
        case .workspaces: .workspacesTab
        case .compose: .composeTab
        case .hosts: .hostsTab
        case .search: .searchTab
        }
    }

    /// SF Symbol for the tab bar and sidebar.
    public var symbolName: String {
        switch self {
        case .home: "bubble.left.and.bubble.right"
        case .feed: "tray.full"
        case .workspaces: "square.stack.3d.up"
        case .compose: "square.and.pencil"
        case .hosts: "desktopcomputer"
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        }
    }

    public var title: String {
        switch self {
        case .home: String(localized: "shell.tab.home", defaultValue: "Home", bundle: .module)
        case .feed: String(localized: "shell.tab.feed", defaultValue: "Feed", bundle: .module)
        case .workspaces: String(localized: "shell.tab.workspaces", defaultValue: "Workspaces", bundle: .module)
        case .compose: String(localized: "shell.tab.compose", defaultValue: "Compose", bundle: .module)
        case .hosts: String(localized: "shell.tab.hosts", defaultValue: "Hosts", bundle: .module)
        case .search: String(localized: "shell.tab.search", defaultValue: "Search", bundle: .module)
        case .settings: String(localized: "shell.tab.settings", defaultValue: "Settings", bundle: .module)
        }
    }

    /// Stable accessibility identifier for UI tests.
    public var accessibilityIdentifier: String { "shell.tab." + rawValue }
}
