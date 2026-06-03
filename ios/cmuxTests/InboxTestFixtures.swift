import Foundation
@testable import cmux_DEV

extension AppDatabase.WorkspaceInboxRow {
    static func fixture(
        workspaceID: String,
        title: String,
        preview: String,
        latestEventSeq: Int,
        lastReadEventSeq: Int,
        lastActivityAt: Date
    ) -> Self {
        AppDatabase.WorkspaceInboxRow(
            workspaceID: workspaceID,
            machineID: "machine_123",
            title: title,
            preview: preview,
            lastActivityAt: lastActivityAt,
            latestEventSeq: latestEventSeq,
            lastReadEventSeq: lastReadEventSeq
        )
    }
}

extension MobileInboxWorkspaceRow {
    static func fixture(
        workspaceID: String,
        machineID: String = "machine_123",
        title: String,
        preview: String,
        latestEventSeq: Int,
        lastReadEventSeq: Int,
        lastActivityAt: Date,
        tmuxSessionName: String = "cmux-nightly",
        machineDisplayName: String = "Mac Mini",
        tailscaleHostname: String? = "cmux-macmini.tail",
        tailscaleIPs: [String] = ["100.64.0.10"]
    ) -> Self {
        MobileInboxWorkspaceRow(
            kind: "workspace",
            workspaceId: workspaceID,
            machineId: machineID,
            title: title,
            preview: preview,
            phase: "idle",
            tmuxSessionName: tmuxSessionName,
            lastActivityAt: lastActivityAt.timeIntervalSince1970 * 1000,
            latestEventSeq: latestEventSeq,
            lastReadEventSeq: lastReadEventSeq,
            unread: latestEventSeq > lastReadEventSeq,
            unreadCount: latestEventSeq > lastReadEventSeq ? 1 : 0,
            machineDisplayName: machineDisplayName,
            machineStatus: .online,
            tailscaleHostname: tailscaleHostname,
            tailscaleIPs: tailscaleIPs
        )
    }
}
