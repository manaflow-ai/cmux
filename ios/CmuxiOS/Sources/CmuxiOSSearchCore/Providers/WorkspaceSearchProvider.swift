public import CmuxiOSFeatureKit
import Foundation

/// Workspaces and their tabs on every Mac, read from C5's `WorkspaceSource`
/// mirror (the same snapshots the Workspaces tab renders).
public struct WorkspaceSearchProvider: SearchProvider {
    private let source: any WorkspaceSource

    public init(source: any WorkspaceSource) {
        self.source = source
    }

    public func items() async -> AsyncStream<[SearchItem]> {
        SearchSnapshotMapping(transform: Self.items(for:)).stream(await source.updates())
    }

    static func items(for hosts: [HostWorkspaces]) -> [SearchItem] {
        var items: [SearchItem] = []
        for host in hosts {
            for workspace in host.workspaces {
                items.append(item(for: workspace, on: host))
                for pane in workspace.panes {
                    for surface in pane.surfaces {
                        items.append(item(for: surface, in: workspace, on: host))
                    }
                }
            }
        }
        return items
    }

    static func item(for workspace: WorkspaceSummary, on host: HostWorkspaces) -> SearchItem {
        var details = [SearchField(SearchText(host.hostName), weight: SearchField.contextWeight)]
        if let group = workspace.group?.name {
            details.append(SearchField(SearchText(group), weight: SearchField.subtitleWeight))
        }
        if let preview = workspace.preview {
            details.append(SearchField(SearchText(preview, limit: SearchField.longTextLimit),
                                       weight: SearchField.bodyWeight, fuzzy: false))
        }
        for pane in workspace.panes {
            for surface in pane.surfaces where surface.title != workspace.title {
                details.append(SearchField(SearchText(surface.title), weight: SearchField.contextWeight, fuzzy: false))
            }
        }
        return SearchItem(
            id: "ws:\(host.hostID.rawValue)/\(workspace.id)", category: .workspaces, title: workspace.title,
            subtitle: SearchCoreText.joined([host.hostName, workspace.preview]),
            symbolName: "square.stack.3d.up",
            destination: .workspace(host: workspace.hostID, workspace: workspace.id, surface: nil),
            details: details, boost: workspace.unreadCount > 0 ? 10 : 0, badge: badge(workspace.status),
            isDimmed: !host.isReachable)
    }

    static func item(for surface: WorkspaceSurface, in workspace: WorkspaceSummary, on host: HostWorkspaces) -> SearchItem {
        var details = [
            SearchField(SearchText(workspace.title), weight: SearchField.contextWeight),
            SearchField(SearchText(host.hostName), weight: SearchField.contextWeight),
        ]
        if let preview = surface.preview {
            details.append(SearchField(SearchText(preview, limit: SearchField.longTextLimit),
                                       weight: SearchField.bodyWeight, fuzzy: false))
        }
        if let url = surface.url {
            details.append(SearchField(SearchText(url.host ?? url.absoluteString), weight: SearchField.subtitleWeight))
        }
        let item = SearchItem(
            id: "tab:\(host.hostID.rawValue)/\(workspace.id)/\(surface.id)", category: .tabs, title: surface.title,
            subtitle: SearchCoreText.joined([workspace.title, host.hostName, surface.preview]),
            symbolName: symbol(surface.kind),
            destination: .workspace(host: workspace.hostID, workspace: workspace.id, surface: surface.id),
            details: details, boost: surface.unreadCount > 0 ? 10 : 0, badge: badge(surface.status),
            isDimmed: !host.isReachable)
        return retitled(item, weight: SearchField.tabTitleWeight)
    }

    /// Tab titles weigh less than workspace titles.
    private static func retitled(_ item: SearchItem, weight: Int) -> SearchItem {
        var item = item
        if let index = item.fields.firstIndex(where: { $0.role == .title }) { item.fields[index].weight = weight }
        return item
    }

    static func badge(_ status: WorkspaceStatus) -> String? {
        switch status {
        case .idle: nil
        case .running: SearchCoreText.running
        case .waitingForInput: SearchCoreText.needsInput
        case .failed: SearchCoreText.failed
        }
    }

    static func symbol(_ kind: WorkspaceSurfaceKind) -> String {
        switch kind {
        case .terminal: "terminal"
        case .browser: "globe"
        case .agent: "sparkles"
        case .other: "square.on.square"
        }
    }
}
