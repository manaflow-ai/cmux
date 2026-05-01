import Foundation

enum MobileMachineStatus: String, Codable, Equatable, Sendable {
    case online
    case offline
    case unknown
}

struct MobileMachineRow: Codable, Equatable, Sendable, Identifiable {
    let teamId: String
    let userId: String
    let machineId: String
    let displayName: String
    let tailscaleHostname: String?
    let tailscaleIPs: [String]
    let status: MobileMachineStatus
    let lastSeenAt: Double
    let lastWorkspaceSyncAt: Double?
    let wsPort: Int?
    let wsSecret: String?

    var id: String { machineId }

    func asTerminalHost() -> TerminalHost {
        let address = preferredAddress
        let host = TerminalHost(
            stableID: machineId,
            name: displayName,
            hostname: address,
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: Self.palette(for: machineId),
            source: .discovered,
            transportPreference: .remoteDaemon,
            teamID: teamId,
            serverID: preferredServerID,
            allowsSSHFallback: true,
            wsPort: wsPort,
            wsSecret: wsSecret,
            machineStatus: status
        )
        return host
    }

    var preferredAddress: String {
        if let tailscaleHostname,
           !tailscaleHostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return tailscaleHostname
        }
        if let firstIP = tailscaleIPs.first,
           !firstIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return firstIP
        }
        return machineId
    }

    var preferredServerID: String {
        let trimmedHostname = tailscaleHostname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedHostname.isEmpty {
            return trimmedHostname
        }
        return machineId
    }

    private static func palette(for machineId: String) -> TerminalHostPalette {
        let palettes = TerminalHostPalette.allCases
        let index = abs(machineId.hashValue) % palettes.count
        return palettes[index]
    }
}

struct MobileInboxWorkspaceRow: Codable, Equatable, Sendable, Identifiable {
    let kind: String?
    let workspaceId: String
    let machineId: String
    let title: String
    let preview: String
    let phase: String
    let tmuxSessionName: String
    let lastActivityAt: Double
    let latestEventSeq: Int
    let lastReadEventSeq: Int
    let unread: Bool
    let unreadCount: Int
    let machineDisplayName: String
    let machineStatus: MobileMachineStatus
    let tailscaleHostname: String?
    let tailscaleIPs: [String]

    var id: String { workspaceId }
}
