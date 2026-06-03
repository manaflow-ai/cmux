import Foundation

struct TerminalServerCatalog {
    let hosts: [TerminalHost]

    init(metadataJSON: String, teamID: String? = nil) throws {
        let data = Data(metadataJSON.utf8)
        let payload = try JSONDecoder().decode(MetadataPayload.self, from: data)
        self.hosts = payload.cmux.servers.map { server in
            TerminalHost(
                stableID: server.id,
                name: server.name,
                hostname: server.hostname,
                port: server.port,
                username: server.username,
                symbolName: server.symbolName,
                palette: server.palette,
                bootstrapCommand: server.bootstrapCommand,
                source: .discovered,
                transportPreference: server.transport,
                teamID: teamID,
                serverID: server.id,
                allowsSSHFallback: server.sshFallback,
                directTLSPins: server.directTLSPins
            )
        }
    }

    static func merge(discovered: [TerminalHost], local: [TerminalHost]) -> [TerminalHost] {
        let discoveredStableIDs = Set(discovered.map(\.stableID))
        var nextSortIndex = (local.map(\.sortIndex).max() ?? -1) + 1

        let mergedDiscovered = discovered.map { host -> TerminalHost in
            guard let existing = preferredLocalMatch(for: host, within: local) else {
                defer { nextSortIndex += 1 }
                return TerminalHost(
                    id: host.id,
                    stableID: host.stableID,
                    name: host.name,
                    hostname: host.hostname,
                    port: host.port,
                    username: host.username,
                    symbolName: host.symbolName,
                    palette: host.palette,
                    bootstrapCommand: host.bootstrapCommand,
                    trustedHostKey: host.trustedHostKey,
                    pendingHostKey: host.pendingHostKey,
                    sortIndex: nextSortIndex,
                    source: .discovered,
                    transportPreference: host.transportPreference,
                    teamID: host.teamID,
                    serverID: host.serverID,
                    allowsSSHFallback: host.allowsSSHFallback,
                    directTLSPins: host.directTLSPins,
                    wsPort: host.wsPort,
                    wsSecret: host.wsSecret,
                    machineStatus: host.machineStatus,
                    daemonWorkspaceChangeSeq: host.daemonWorkspaceChangeSeq
                )
            }

            return TerminalHost(
                id: existing.id,
                stableID: host.stableID,
                name: host.name,
                hostname: host.hostname,
                port: host.port,
                username: host.username,
                symbolName: host.symbolName,
                palette: host.palette,
                bootstrapCommand: existing.bootstrapCommand,
                trustedHostKey: existing.trustedHostKey,
                pendingHostKey: existing.pendingHostKey,
                sortIndex: existing.sortIndex,
                source: .discovered,
                transportPreference: host.transportPreference,
                sshAuthenticationMethod: existing.sshAuthenticationMethod,
                teamID: host.teamID,
                serverID: host.serverID,
                allowsSSHFallback: existing.allowsSSHFallback,
                directTLSPins: host.directTLSPins,
                wsPort: host.wsPort,
                wsSecret: host.wsSecret,
                machineStatus: host.machineStatus,
                daemonWorkspaceChangeSeq: host.daemonWorkspaceChangeSeq
            )
        }

        let retainedCustomHosts = local.filter { host in
            host.source == .custom &&
                !discoveredStableIDs.contains(host.stableID) &&
                !discovered.contains(where: { shadowsPlaceholder(host, with: $0) })
        }

        return (retainedCustomHosts + mergedDiscovered).sorted(by: TerminalServerCatalog.sortHosts)
    }

    static func representsSameMachine(_ lhs: TerminalHost, _ rhs: TerminalHost) -> Bool {
        if normalized(lhs.stableID) == normalized(rhs.stableID) {
            return true
        }

        let lhsServerID = normalized(lhs.serverID)
        let rhsServerID = normalized(rhs.serverID)
        if !lhsServerID.isEmpty, lhsServerID == rhsServerID {
            return true
        }

        let lhsHostname = normalized(lhs.hostname)
        let rhsHostname = normalized(rhs.hostname)
        return !lhsHostname.isEmpty && lhsHostname == rhsHostname
    }

    private static func sortHosts(_ lhs: TerminalHost, _ rhs: TerminalHost) -> Bool {
        if lhs.sortIndex != rhs.sortIndex {
            return lhs.sortIndex < rhs.sortIndex
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func preferredLocalMatch(
        for discovered: TerminalHost,
        within local: [TerminalHost]
    ) -> TerminalHost? {
        if let stableIDMatch = local.first(where: {
            normalized($0.stableID) == normalized(discovered.stableID)
        }) {
            return stableIDMatch
        }

        if let serverIDMatch = local.first(where: {
            let serverID = normalized(discovered.serverID)
            return !serverID.isEmpty && normalized($0.serverID) == serverID
        }) {
            return serverIDMatch
        }

        if let hostnameMatch = local.first(where: {
            let hostname = normalized(discovered.hostname)
            return !hostname.isEmpty &&
                $0.source == .discovered &&
                normalized($0.hostname) == hostname
        }) {
            return hostnameMatch
        }

        return local.first(where: { shadowsPlaceholder($0, with: discovered) })
    }

    private static func shadowsPlaceholder(_ local: TerminalHost, with discovered: TerminalHost) -> Bool {
        guard local.source == .custom, !local.isConfigured else {
            return false
        }

        if representsSameMachine(local, discovered) {
            return true
        }

        let localName = normalized(local.name)
        let discoveredName = normalized(discovered.name)
        return !localName.isEmpty && localName == discoveredName
    }

    private static func normalized(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }
}

private struct MetadataPayload: Decodable {
    let cmux: MetadataNamespace
}

private struct MetadataNamespace: Decodable {
    let servers: [MetadataServer]
}

private struct MetadataServer: Decodable {
    let id: String
    let name: String
    let hostname: String
    let port: Int
    let username: String
    let symbolName: String
    let palette: TerminalHostPalette
    let transport: TerminalTransportPreference
    let bootstrapCommand: String
    let sshFallback: Bool
    let directTLSPins: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case hostname
        case port
        case username
        case symbolName
        case palette
        case transport
        case bootstrapCommand
        case sshFallback = "ssh_fallback"
        case directTLSPins = "direct_tls_pins"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        hostname = try container.decode(String.self, forKey: .hostname)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try container.decode(String.self, forKey: .username)
        symbolName = try container.decodeIfPresent(String.self, forKey: .symbolName) ?? "server.rack"
        palette = try container.decodeIfPresent(TerminalHostPalette.self, forKey: .palette) ?? .mint
        transport = try container.decodeIfPresent(TerminalTransportPreference.self, forKey: .transport) ?? .rawSSH
        bootstrapCommand = try container.decodeIfPresent(String.self, forKey: .bootstrapCommand) ??
            "tmux new-session -A -s {{session}}"
        sshFallback = try container.decodeIfPresent(Bool.self, forKey: .sshFallback) ?? true
        if let pins = try container.decodeIfPresent([String].self, forKey: .directTLSPins) {
            directTLSPins = pins.normalizedTerminalPins
        } else if let pin = try container.decodeIfPresent(String.self, forKey: .directTLSPins) {
            directTLSPins = [pin].normalizedTerminalPins
        } else {
            directTLSPins = []
        }
    }
}
