import CmuxiOSFeatureKit
import CmuxiOSSearch
import CmuxiOSSearchCore
import CmuxiOSShell

/// Builds lane C15's search over the account's seams: the providers read
/// the same mirrors the Workspaces, Feed and Hosts tabs render.
@MainActor
enum SearchComposition {
    static func makeFeature(sources: FeatureSources, visibleTabs: [ShellTab], opener: any SearchOpening) -> SearchFeature {
        var actions: [SearchAction] = [.pairMac]
        if visibleTabs.contains(.compose) { actions.insert(.newTask, at: 0) }
        if visibleTabs.contains(.hosts) { actions.append(.addSSHHost) }
        let providers: [any SearchProvider] = [
            SearchCatalog(actions: actions).provider,
            WorkspaceSearchProvider(source: sources.workspaces),
            FeedSearchProvider(source: sources.feed),
            HostSearchProvider(store: sources.hosts),
        ]
        return SearchFeature(providers: providers, catalog: SearchCatalog(actions: actions), opener: opener)
    }
}
