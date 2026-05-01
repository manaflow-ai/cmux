import Foundation

enum UnifiedInboxKind: String, Codable, Equatable, Sendable {
    case conversation
    case workspace
}

struct UnifiedInboxItem: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let kind: UnifiedInboxKind
    let conversationID: String?
    let workspaceID: String?
    let machineID: String?
    let teamID: String?
    let title: String
    let preview: String
    let unreadCount: Int
    let sortDate: Date
    let accessoryLabel: String?
    let symbolName: String?
    let tmuxSessionName: String?
    let latestEventSeq: Int?
    let lastReadEventSeq: Int?
    let tailscaleHostname: String?
    let tailscaleIPs: [String]
    let machineStatus: MobileMachineStatus?

    init(
        kind: UnifiedInboxKind,
        conversationID: String? = nil,
        workspaceID: String? = nil,
        machineID: String? = nil,
        teamID: String? = nil,
        title: String,
        preview: String,
        unreadCount: Int,
        sortDate: Date,
        accessoryLabel: String? = nil,
        symbolName: String? = nil,
        tmuxSessionName: String? = nil,
        latestEventSeq: Int? = nil,
        lastReadEventSeq: Int? = nil,
        tailscaleHostname: String? = nil,
        tailscaleIPs: [String] = [],
        machineStatus: MobileMachineStatus? = nil
    ) {
        self.kind = kind
        self.conversationID = conversationID
        self.workspaceID = workspaceID
        self.machineID = machineID
        self.teamID = teamID
        self.title = title
        self.preview = preview
        self.unreadCount = unreadCount
        self.sortDate = sortDate
        self.accessoryLabel = accessoryLabel
        self.symbolName = symbolName
        self.tmuxSessionName = tmuxSessionName
        self.latestEventSeq = latestEventSeq
        self.lastReadEventSeq = lastReadEventSeq
        self.tailscaleHostname = tailscaleHostname
        self.tailscaleIPs = tailscaleIPs
        self.machineStatus = machineStatus

        switch kind {
        case .conversation:
            self.id = "conversation:\(conversationID ?? UUID().uuidString)"
        case .workspace:
            self.id = "workspace:\(workspaceID ?? UUID().uuidString)"
        }
    }

    var isUnread: Bool {
        unreadCount > 0
    }

    func matches(query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !normalized.isEmpty else { return true }
        return title.localizedLowercase.contains(normalized) ||
            preview.localizedLowercase.contains(normalized) ||
            (accessoryLabel?.localizedLowercase.contains(normalized) ?? false)
    }
}

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

    init(workspaceRow: MobileInboxWorkspaceRow, teamID: String) {
        self.init(
            kind: .workspace,
            workspaceID: workspaceRow.workspaceId,
            machineID: workspaceRow.machineId,
            teamID: teamID,
            title: workspaceRow.title,
            preview: workspaceRow.preview.isEmpty ? "No recent activity" : workspaceRow.preview,
            unreadCount: workspaceRow.unreadCount,
            sortDate: workspaceRow.lastActivityAt > 0
                ? Date(timeIntervalSince1970: workspaceRow.lastActivityAt / 1000)
                : Date(),
            accessoryLabel: workspaceRow.machineDisplayName,
            symbolName: "terminal",
            tmuxSessionName: workspaceRow.tmuxSessionName,
            latestEventSeq: workspaceRow.latestEventSeq,
            lastReadEventSeq: workspaceRow.lastReadEventSeq,
            tailscaleHostname: workspaceRow.tailscaleHostname,
            tailscaleIPs: workspaceRow.tailscaleIPs,
            machineStatus: workspaceRow.machineStatus
        )
    }
}
