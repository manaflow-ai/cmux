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
    /// Lane C12: the Cloud tab (c12-cloud.md).
    case cloudTab
    /// Lane C12: onboarding offers to create the first Cloud machine.
    case cloudOnboarding
    /// Lane C12: Cloud machines' workspaces in the Workspaces list. Off until
    /// the VM runs the cmux host (phase 2), so no socket is opened that
    /// HostDO would refuse.
    case cloudWorkspaces
    /// Lane E5: the Keep Mac Awake onboarding card. Off until D1b registers
    /// the Mac's power assertion behind `KeepAwakeControl`.
    case keepAwake

    /// The core tabs are shipped surfaces and must be available in a release
    /// build even when remote configuration is unavailable. Remote config and
    /// the launch environment can still disable them for a staged rollout.
    public func defaultValue(isDebug: Bool) -> Bool {
        _ = isDebug
        switch self {
        case .feedTab, .workspacesTab, .composeTab, .hostsTab, .searchTab, .cloudTab: true
        case .iPadSidebar: true
        case .billing, .cloudOnboarding, .cloudWorkspaces, .keepAwake: false
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
        case .cloudTab: String(localized: "shell.flag.cloudTab", defaultValue: "Cloud Tab", bundle: .module)
        case .cloudOnboarding: String(localized: "shell.flag.cloudOnboarding", defaultValue: "Cloud Onboarding", bundle: .module)
        case .cloudWorkspaces: String(localized: "shell.flag.cloudWorkspaces", defaultValue: "Cloud Workspaces", bundle: .module)
        case .keepAwake: String(localized: "shell.flag.keepAwake", defaultValue: "Keep Mac Awake Card", bundle: .module)
        }
    }
}
