import CmuxiOSFeatureKit
import Foundation

/// Workspaces tab placeholder over `WorkspaceSource`: one section per host.
enum WorkspacesPlaceholder {
    static func stream(_ source: any WorkspaceSource, isMock: Bool) -> PlaceholderSnapshot.Factory {
        PlaceholderSnapshot.stream(isMock: isMock, { await source.updates() }, sections: sections)
    }

    @Sendable static func sections(_ hosts: [HostWorkspaces]) -> [PlaceholderSection] {
        hosts.map { host in
            let title = host.isReachable ? host.hostName : host.hostName + " · " + ShellText.unreachable
            return PlaceholderSection(id: host.hostID.rawValue, title: title, rows: host.workspaces.map { workspace in
                let status = status(workspace.status)
                return PlaceholderRow(
                    id: workspace.id, title: workspace.title,
                    subtitle: ShellText.status(status) + " · " + ShellText.paneCount(workspace.paneCount),
                    symbolName: "square.stack.3d.up", status: status, badge: workspace.unreadCount)
            })
        }
    }

    static func status(_ status: WorkspaceStatus) -> PlaceholderStatus {
        switch status {
        case .idle: .idle
        case .running: .running
        case .waitingForInput: .waiting
        case .failed: .failed
        }
    }
}
