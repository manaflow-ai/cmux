import Foundation

/// The command palette's actions and the settings pages, with localized
/// titles and the extra words people type for them.
public struct SearchCatalog: Sendable {
    public let actions: [SearchItem]
    public let settings: [SearchItem]

    /// - Parameters:
    ///   - actions: the actions this build can run (the composition root
    ///     drops one whose screen is hidden).
    ///   - settings: the settings pages this build has.
    public init(actions: [SearchAction] = SearchAction.allCases, settings: [SearchSettingsPage] = SearchSettingsPage.allCases) {
        self.actions = actions.map(Self.item(for:))
        self.settings = settings.map(Self.item(for:))
    }

    /// Everything, as one provider.
    public var provider: StaticSearchProvider { StaticSearchProvider(actions + settings) }

    static func item(for action: SearchAction) -> SearchItem {
        let (title, keywords, symbol): (String, String, String) = switch action {
        case .newTask: (
            String(localized: "search.action.new-task", defaultValue: "New Task", bundle: .module),
            String(localized: "search.action.new-task.keywords", defaultValue: "compose agent prompt run", bundle: .module),
            "square.and.pencil")
        case .pairMac: (
            String(localized: "search.action.pair-mac", defaultValue: "Pair a Mac", bundle: .module),
            String(localized: "search.action.pair-mac.keywords", defaultValue: "scan QR code connect computer", bundle: .module),
            "qrcode.viewfinder")
        case .addSSHHost: (
            String(localized: "search.action.add-ssh-host", defaultValue: "Add SSH Host", bundle: .module),
            String(localized: "search.action.add-ssh-host.keywords", defaultValue: "server machine remote", bundle: .module),
            "plus.rectangle.on.rectangle")
        }
        return SearchItem(id: "action:\(action.rawValue)", category: .actions, title: title, symbolName: symbol,
                          destination: .action(action), keywords: split(keywords))
    }

    static func item(for page: SearchSettingsPage) -> SearchItem {
        let (title, keywords, symbol): (String, String, String) = switch page {
        case .main: (
            String(localized: "search.settings.main", defaultValue: "Settings", bundle: .module),
            String(localized: "search.settings.main.keywords", defaultValue: "preferences options", bundle: .module),
            "gearshape")
        case .account: (
            String(localized: "search.settings.account", defaultValue: "Account", bundle: .module),
            String(localized: "search.settings.account.keywords", defaultValue: "sign out team profile email", bundle: .module),
            "person.crop.circle")
        case .devices: (
            String(localized: "search.settings.devices", defaultValue: "Devices & Macs", bundle: .module),
            String(localized: "search.settings.devices.keywords", defaultValue: "paired revoke computers", bundle: .module),
            "laptopcomputer.and.iphone")
        case .terminal: (
            String(localized: "search.settings.terminal", defaultValue: "Terminal Settings", bundle: .module),
            String(localized: "search.settings.terminal.keywords", defaultValue: "font theme color key bar", bundle: .module),
            "terminal")
        case .notifications: (
            String(localized: "search.settings.notifications", defaultValue: "Notification Settings", bundle: .module),
            String(localized: "search.settings.notifications.keywords", defaultValue: "push alerts badge sounds", bundle: .module),
            "bell.badge")
        case .privacy: (
            String(localized: "search.settings.privacy", defaultValue: "Privacy", bundle: .module),
            String(localized: "search.settings.privacy.keywords", defaultValue: "telemetry crash reports", bundle: .module),
            "hand.raised")
        case .diagnostics: (
            String(localized: "search.settings.diagnostics", defaultValue: "Diagnostics", bundle: .module),
            String(localized: "search.settings.diagnostics.keywords", defaultValue: "logs support export", bundle: .module),
            "stethoscope")
        case .whatsNew: (
            String(localized: "search.settings.whats-new", defaultValue: "What's New", bundle: .module),
            String(localized: "search.settings.whats-new.keywords", defaultValue: "release notes changes", bundle: .module),
            "sparkles")
        }
        return SearchItem(id: "settings:\(page.rawValue)", category: .settings, title: title, symbolName: symbol,
                          destination: .settings(page), keywords: split(keywords))
    }

    /// Keywords are one localized, space-separated string per entry, so a
    /// translator sees them together.
    static func split(_ keywords: String) -> [String] {
        keywords.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}
