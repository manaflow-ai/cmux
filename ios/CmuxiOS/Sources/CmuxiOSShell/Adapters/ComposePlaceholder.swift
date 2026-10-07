import CmuxiOSFeatureKit
import Foundation

/// Compose tab placeholder over `TaskComposerSink`: what the pickers offer.
enum ComposePlaceholder {
    static func stream(_ sink: any TaskComposerSink, isMock: Bool) -> PlaceholderStream.Factory {
        PlaceholderStream.map(isMock: isMock, { await sink.catalog() }, sections: sections)
    }

    @Sendable static func sections(_ catalog: ComposerCatalog) -> [PlaceholderSection] {
        [
            PlaceholderSection(id: "hosts", title: ShellText.hostsSection, rows: catalog.hosts.map { host in
                PlaceholderRow(
                    id: host.hostID.rawValue, title: host.hostName,
                    subtitle: (host.isReachable ? ShellText.reachable : ShellText.unreachable) + " · "
                        + ShellText.workspaceCount(host.workspaces.count),
                    symbolName: "desktopcomputer", status: host.isReachable ? .running : .idle)
            }),
            PlaceholderSection(id: "agents", title: ShellText.agentsSection, rows: catalog.agents.map { agent in
                PlaceholderRow(id: agent.id, title: agent.name,
                               subtitle: agent.models.joined(separator: ", ") + " · " + agent.efforts.joined(separator: ", "),
                               symbolName: "sparkles")
            }),
        ]
    }
}
