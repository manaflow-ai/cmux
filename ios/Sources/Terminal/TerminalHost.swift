import Foundation

enum TerminalHostPalette: String, Codable, CaseIterable, Sendable {
    case sky
    case mint
    case amber
    case rose
}

enum TerminalConnectionPhase: String, Codable, CaseIterable, Sendable {
    case needsConfiguration
    case idle
    case connecting
    case connected
    case reconnecting
    case disconnected
    case failed
}

enum TerminalHostSource: String, Codable, CaseIterable, Sendable {
    case discovered
    case custom
}

enum TerminalTransportPreference: String, Codable, CaseIterable, Sendable {
    case rawSSH = "raw-ssh"
    case remoteDaemon = "cmuxd-remote"
}

enum TerminalSSHAuthenticationMethod: String, Codable, CaseIterable, Sendable {
    case password
    case privateKey = "private-key"
}

struct TerminalSSHCredentials: Equatable, Sendable {
    var password: String?
    var privateKey: String?

    var hasPassword: Bool {
        !(password?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var hasPrivateKey: Bool {
        !(privateKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func hasCredential(for method: TerminalSSHAuthenticationMethod) -> Bool {
        switch method {
        case .password:
            hasPassword
        case .privateKey:
            hasPrivateKey
        }
    }

    var normalized: Self {
        Self(
            password: password?.trimmingCharacters(in: .whitespacesAndNewlines),
            privateKey: privateKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

extension Array where Element == String {
    var normalizedTerminalPins: [String] {
        var seen = Set<String>()
        return compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }
}

struct TerminalRemoteDaemonResumeState: Codable, Equatable, Sendable {
    var sessionID: String
    var attachmentID: String
    var readOffset: UInt64
}

struct TerminalHost: Identifiable, Codable, Equatable, Sendable {
    typealias ID = UUID

    let id: ID
    var stableID: String
    var name: String
    var hostname: String
    var port: Int
    var username: String
    var symbolName: String
    var palette: TerminalHostPalette
    var bootstrapCommand: String
    var trustedHostKey: String?
    var pendingHostKey: String?
    var sortIndex: Int
    var source: TerminalHostSource
    var transportPreference: TerminalTransportPreference
    var sshAuthenticationMethod: TerminalSSHAuthenticationMethod
    var teamID: String?
    var serverID: String?
    var allowsSSHFallback: Bool
    var directTLSPins: [String]
    var wsPort: Int?
    var wsSecret: String?
    var machineStatus: MobileMachineStatus?
    var daemonWorkspaceChangeSeq: UInt64?

    init(
        id: ID = UUID(),
        stableID: String? = nil,
        name: String,
        hostname: String,
        port: Int = 22,
        username: String,
        symbolName: String,
        palette: TerminalHostPalette,
        bootstrapCommand: String = "tmux new-session -A -s {{session}}",
        trustedHostKey: String? = nil,
        pendingHostKey: String? = nil,
        sortIndex: Int = 0,
        source: TerminalHostSource = .custom,
        transportPreference: TerminalTransportPreference = .rawSSH,
        sshAuthenticationMethod: TerminalSSHAuthenticationMethod = .password,
        teamID: String? = nil,
        serverID: String? = nil,
        allowsSSHFallback: Bool = true,
        directTLSPins: [String] = [],
        wsPort: Int? = nil,
        wsSecret: String? = nil,
        machineStatus: MobileMachineStatus? = nil,
        daemonWorkspaceChangeSeq: UInt64? = nil
    ) {
        self.id = id
        self.stableID = stableID ?? id.uuidString
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.symbolName = symbolName
        self.palette = palette
        self.bootstrapCommand = bootstrapCommand
        self.trustedHostKey = trustedHostKey
        self.pendingHostKey = pendingHostKey
        self.sortIndex = sortIndex
        self.source = source
        self.transportPreference = transportPreference
        self.sshAuthenticationMethod = sshAuthenticationMethod
        self.teamID = teamID
        self.serverID = serverID
        self.allowsSSHFallback = allowsSSHFallback
        self.directTLSPins = directTLSPins.normalizedTerminalPins
        self.wsPort = wsPort
        self.wsSecret = wsSecret
        self.machineStatus = machineStatus
        self.daemonWorkspaceChangeSeq = daemonWorkspaceChangeSeq
    }

    var hasWebSocketEndpoint: Bool {
        wsPort != nil && !(wsSecret?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var subtitle: String {
        guard !hostname.isEmpty, !username.isEmpty else {
            return String(
                localized: "terminal.host.setup_required",
                defaultValue: "SSH setup required"
            )
        }
        return "\(username)@\(hostname)"
    }

    var isConfigured: Bool {
        !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var accessibilitySlug: String {
        name.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    var accessibilityIdentifierSlug: String {
        stableID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
    }

    var effectiveServerID: String {
        serverID ?? stableID
    }

    var hasDirectDaemonTeamScope: Bool {
        !(teamID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var requiresSavedSSHPassword: Bool {
        if hasWebSocketEndpoint { return false }
        return switch transportPreference {
        case .rawSSH:
            sshAuthenticationMethod == .password
        case .remoteDaemon:
            !hasDirectDaemonTeamScope && sshAuthenticationMethod == .password
        }
    }

    var requiresSavedSSHPrivateKey: Bool {
        if hasWebSocketEndpoint { return false }
        return switch transportPreference {
        case .rawSSH:
            sshAuthenticationMethod == .privateKey
        case .remoteDaemon:
            !hasDirectDaemonTeamScope && sshAuthenticationMethod == .privateKey
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case stableID
        case name
        case hostname
        case port
        case username
        case symbolName
        case palette
        case bootstrapCommand
        case trustedHostKey
        case pendingHostKey
        case sortIndex
        case source
        case transportPreference
        case sshAuthenticationMethod
        case teamID
        case serverID
        case allowsSSHFallback
        case directTLSPins
        case wsPort
        case wsSecret
        case machineStatus
        case daemonWorkspaceChangeSeq
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(ID.self, forKey: .id)
        let hostname = try container.decode(String.self, forKey: .hostname)
        let source = try container.decodeIfPresent(TerminalHostSource.self, forKey: .source) ?? .custom
        self.init(
            id: id,
            stableID: try container.decodeIfPresent(String.self, forKey: .stableID) ?? Self.legacyStableID(
                hostname: hostname,
                fallbackID: id
            ),
            name: try container.decode(String.self, forKey: .name),
            hostname: hostname,
            port: try container.decode(Int.self, forKey: .port),
            username: try container.decode(String.self, forKey: .username),
            symbolName: try container.decode(String.self, forKey: .symbolName),
            palette: try container.decode(TerminalHostPalette.self, forKey: .palette),
            bootstrapCommand: try container.decode(String.self, forKey: .bootstrapCommand),
            trustedHostKey: try container.decodeIfPresent(String.self, forKey: .trustedHostKey),
            pendingHostKey: try container.decodeIfPresent(String.self, forKey: .pendingHostKey),
            sortIndex: try container.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0,
            source: source,
            transportPreference: try container.decodeIfPresent(TerminalTransportPreference.self, forKey: .transportPreference) ?? .rawSSH,
            sshAuthenticationMethod: try container.decodeIfPresent(
                TerminalSSHAuthenticationMethod.self,
                forKey: .sshAuthenticationMethod
            ) ?? .password,
            teamID: try container.decodeIfPresent(String.self, forKey: .teamID),
            serverID: try container.decodeIfPresent(String.self, forKey: .serverID),
            allowsSSHFallback: try container.decodeIfPresent(Bool.self, forKey: .allowsSSHFallback) ?? true,
            directTLSPins: try container.decodeIfPresent([String].self, forKey: .directTLSPins) ?? [],
            wsPort: try container.decodeIfPresent(Int.self, forKey: .wsPort),
            wsSecret: try container.decodeIfPresent(String.self, forKey: .wsSecret),
            machineStatus: try container.decodeIfPresent(MobileMachineStatus.self, forKey: .machineStatus),
            daemonWorkspaceChangeSeq: try container.decodeIfPresent(UInt64.self, forKey: .daemonWorkspaceChangeSeq)
        )
    }

    private static func legacyStableID(hostname: String, fallbackID: ID) -> String {
        let trimmedHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHostname.isEmpty {
            return trimmedHostname.lowercased()
        }
        return fallbackID.uuidString
    }
}
