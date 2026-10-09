import CmuxiOSFeatureKit
import Foundation

/// Workspaces tab placeholder over `WorkspaceSource`: one section per host,
/// followed by that host's browser tabs when a browser screen is wired
/// (rows `browser:<tab id>`, opened through `SurfaceScreenFactories`).
enum WorkspacesPlaceholder {
    static let browserRowPrefix = "browser:"

    static func stream(_ source: any WorkspaceSource, isMock: Bool) -> PlaceholderSnapshot.Factory {
        PlaceholderSnapshot.stream(isMock: isMock, { await source.updates() }, sections: { sections($0) })
    }

    /// Workspaces plus each host's browser tabs (the first snapshot of
    /// `browser.tabs(on:)` per host, read when the workspace list changes).
    static func stream(_ source: any WorkspaceSource, browser: any BrowserStreamSource, isMock: Bool) -> PlaceholderSnapshot.Factory {
        {
            AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let task = Task {
                    for await snapshot in await source.updates() {
                        var tabs: [HostID: [BrowserTabInfo]] = [:]
                        for host in snapshot.value {
                            for await first in await browser.tabs(on: host.hostID) {
                                tabs[host.hostID] = first.value
                                break
                            }
                        }
                        continuation.yield(PlaceholderSnapshot(connection: snapshot.connection, isMock: isMock,
                                                               sections: sections(snapshot.value, browserTabs: tabs)))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    @Sendable static func sections(_ hosts: [HostWorkspaces], browserTabs: [HostID: [BrowserTabInfo]] = [:]) -> [PlaceholderSection] {
        hosts.map { host in
            let title = host.isReachable ? host.hostName : host.hostName + " · " + ShellText.unreachable
            let workspaces = host.workspaces.map { workspace in
                let status = status(workspace.status)
                return PlaceholderRow(
                    id: workspace.id, title: workspace.title,
                    subtitle: ShellText.status(status) + " · " + ShellText.paneCount(workspace.paneCount),
                    symbolName: "square.stack.3d.up", status: status, badge: workspace.unreadCount)
            }
            let browsers = (browserTabs[host.hostID] ?? []).map { tab in
                PlaceholderRow(id: browserRowPrefix + tab.id, title: tab.title,
                               subtitle: ShellText.browserTab + (tab.url.map { " · " + ($0.host() ?? $0.absoluteString) } ?? ""),
                               symbolName: "globe", opens: true)
            }
            return PlaceholderSection(id: host.hostID.rawValue, title: title, rows: workspaces + browsers)
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
