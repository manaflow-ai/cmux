import Foundation

/// Build-time defaults with DEV overrides. A flag gates an unfinished
/// surface; it is removed once the surface ships.
public enum ShellFeatureFlag: String, CaseIterable, Hashable, Sendable {
    case feedTab
    case workspacesTab
    case composeTab
    case hostsTab
    /// Universal search (c15-search.md).
    case searchTab
    /// iPad: the tab bar adapts into a sidebar (iOS 18 and later).
    case iPadSidebar
    /// Settings > Plans (StoreKit billing stub, c16-platform.md section 8).
    case billing

    /// On in DEBUG so lanes see their tab; off in Release until the lane ships.
    public func defaultValue(isDebug: Bool) -> Bool {
        switch self {
        case .feedTab, .workspacesTab, .composeTab, .hostsTab, .searchTab: isDebug
        case .iPadSidebar: true
        case .billing: false
        }
    }

    /// Launch override, for example `CMUX_IOS_FLAG_FEED_TAB=0`.
    public var environmentKey: String {
        var name = ""
        for character in rawValue {
            if character.isUppercase { name += "_" }
            name += character.uppercased()
        }
        return "CMUX_IOS_FLAG_" + name
    }

    public var title: String {
        switch self {
        case .feedTab: String(localized: "shell.flag.feedTab", defaultValue: "Feed Tab", bundle: .module)
        case .workspacesTab: String(localized: "shell.flag.workspacesTab", defaultValue: "Workspaces Tab", bundle: .module)
        case .composeTab: String(localized: "shell.flag.composeTab", defaultValue: "Compose Tab", bundle: .module)
        case .hostsTab: String(localized: "shell.flag.hostsTab", defaultValue: "Hosts Tab", bundle: .module)
        case .searchTab: String(localized: "shell.flag.searchTab", defaultValue: "Search Tab", bundle: .module)
        case .iPadSidebar: String(localized: "shell.flag.iPadSidebar", defaultValue: "iPad Sidebar", bundle: .module)
        case .billing: String(localized: "shell.flag.billing", defaultValue: "Plans (Billing)", bundle: .module)
        }
    }
}
