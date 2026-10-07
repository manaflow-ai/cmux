public import CmuxiOSFeatureKit

/// Where a result goes. The composition root maps each case onto the
/// existing router and feature entry points (`SearchOpening`).
public enum SearchDestination: Hashable, Sendable {
    case workspace(host: HostID, workspace: String, surface: String?)
    case feedItem(String)
    case host(HostID, SearchHostKind)
    case settings(SearchSettingsPage)
    case action(SearchAction)
}
