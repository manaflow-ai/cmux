import CmuxInboxCore
import Foundation

// The UnifiedInboxItem / UnifiedInboxKind value types moved to the CmuxInboxCore package
// (iOS refactor wave 1). This file keeps only the app-side mapping from the GRDB row type,
// which references AppDatabase.WorkspaceInboxRow and cannot move down into a Core package.
extension UnifiedInboxItem {
    init(workspaceRow: AppDatabase.WorkspaceInboxRow) {
        self.init(
            kind: .workspace,
            workspaceID: workspaceRow.workspaceID,
            machineID: workspaceRow.machineID,
            teamID: workspaceRow.teamID,
            title: workspaceRow.title,
            preview: workspaceRow.preview.isEmpty ? "No recent activity" : workspaceRow.preview,
            unreadCount: workspaceRow.unreadCount,
            sortDate: workspaceRow.lastActivityAt,
            accessoryLabel: workspaceRow.machineDisplayName ?? workspaceRow.machineID,
            symbolName: "terminal",
            tmuxSessionName: workspaceRow.tmuxSessionName,
            latestEventSeq: workspaceRow.latestEventSeq,
            lastReadEventSeq: workspaceRow.lastReadEventSeq,
            tailscaleHostname: workspaceRow.tailscaleHostname,
            tailscaleIPs: workspaceRow.tailscaleIPs
        )
    }
}
