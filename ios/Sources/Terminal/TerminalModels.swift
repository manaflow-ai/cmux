import Foundation
import Security

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

enum MobileMachineStatus: String, Codable, CaseIterable, Sendable {
    case online
    case offline
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
    /// Runtime-only machine status propagated by the server discovery layer (Unit 6).
    /// Not persisted. Defaults to nil (treated as online).
    var machineStatus: MobileMachineStatus?

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
        machineStatus: MobileMachineStatus? = nil
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
        self.machineStatus = machineStatus
    }

    var subtitle: String {
        guard !hostname.isEmpty, !username.isEmpty else { return TerminalModelStrings.setupRequiredSubtitle }
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
        switch transportPreference {
        case .rawSSH:
            sshAuthenticationMethod == .password
        case .remoteDaemon:
            !hasDirectDaemonTeamScope && sshAuthenticationMethod == .password
        }
    }

    var requiresSavedSSHPrivateKey: Bool {
        switch transportPreference {
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
            directTLSPins: try container.decodeIfPresent([String].self, forKey: .directTLSPins) ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(stableID, forKey: .stableID)
        try container.encode(name, forKey: .name)
        try container.encode(hostname, forKey: .hostname)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(symbolName, forKey: .symbolName)
        try container.encode(palette, forKey: .palette)
        try container.encode(bootstrapCommand, forKey: .bootstrapCommand)
        try container.encodeIfPresent(trustedHostKey, forKey: .trustedHostKey)
        try container.encodeIfPresent(pendingHostKey, forKey: .pendingHostKey)
        try container.encode(sortIndex, forKey: .sortIndex)
        try container.encode(source, forKey: .source)
        try container.encode(transportPreference, forKey: .transportPreference)
        try container.encode(sshAuthenticationMethod, forKey: .sshAuthenticationMethod)
        try container.encodeIfPresent(teamID, forKey: .teamID)
        try container.encodeIfPresent(serverID, forKey: .serverID)
        try container.encode(allowsSSHFallback, forKey: .allowsSSHFallback)
        try container.encode(directTLSPins, forKey: .directTLSPins)
    }

    private static func legacyStableID(hostname: String, fallbackID: ID) -> String {
        let trimmedHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHostname.isEmpty {
            return trimmedHostname.lowercased()
        }
        return fallbackID.uuidString
    }
}

struct TerminalWorkspace: Identifiable, Codable, Equatable, Sendable {
    typealias ID = UUID

    let id: ID
    var hostID: TerminalHost.ID
    var title: String
    var tmuxSessionName: String
    var preview: String
    var lastActivity: Date
    var unread: Bool
    var phase: TerminalConnectionPhase
    var lastError: String?
    var remoteWorkspaceID: String?
    var backendIdentity: TerminalWorkspaceBackendIdentity?
    var backendMetadata: TerminalWorkspaceBackendMetadata?
    var remoteDaemonResumeState: TerminalRemoteDaemonResumeState?

    init(
        id: ID = UUID(),
        hostID: TerminalHost.ID,
        title: String,
        tmuxSessionName: String,
        preview: String = "",
        lastActivity: Date = .now,
        unread: Bool = false,
        phase: TerminalConnectionPhase = .idle,
        lastError: String? = nil,
        remoteWorkspaceID: String? = nil,
        backendIdentity: TerminalWorkspaceBackendIdentity? = nil,
        backendMetadata: TerminalWorkspaceBackendMetadata? = nil,
        remoteDaemonResumeState: TerminalRemoteDaemonResumeState? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.title = title
        self.tmuxSessionName = tmuxSessionName
        self.preview = preview
        self.lastActivity = lastActivity
        self.unread = unread
        self.phase = phase
        self.lastError = lastError
        self.remoteWorkspaceID = remoteWorkspaceID
        self.backendIdentity = backendIdentity
        self.backendMetadata = backendMetadata
        self.remoteDaemonResumeState = remoteDaemonResumeState
    }

    var isRemoteWorkspace: Bool {
        !(remoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

struct TerminalStoreSnapshot: Codable, Equatable, Sendable {
    var version = 1
    var hosts: [TerminalHost]
    var workspaces: [TerminalWorkspace]
    var selectedWorkspaceID: TerminalWorkspace.ID?

    static func empty() -> Self {
        Self(
            hosts: [],
            workspaces: [],
            selectedWorkspaceID: nil
        )
    }

    static func seed() -> Self {
        Self(
            hosts: [
                TerminalHost(
                    name: TerminalModelStrings.seedHostName,
                    hostname: "cmux-macmini",
                    username: "cmux",
                    symbolName: "desktopcomputer",
                    palette: .mint,
                    sortIndex: 0
                )
            ],
            workspaces: [],
            selectedWorkspaceID: nil
        )
    }
}

protocol TerminalSnapshotPersisting {
    func load() -> TerminalStoreSnapshot
    func save(_ snapshot: TerminalStoreSnapshot) throws
}

final class TerminalSnapshotStore: TerminalSnapshotPersisting {
    private let fileURL: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> TerminalStoreSnapshot {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? decoder.decode(TerminalStoreSnapshot.self, from: data) else {
            return .empty()
        }

        return snapshot
    }

    func save(_ snapshot: TerminalStoreSnapshot) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory
        return baseURL.appendingPathComponent("terminal-store.json")
    }
}

protocol TerminalCredentialsStoring {
    func password(for hostID: TerminalHost.ID) -> String?
    func privateKey(for hostID: TerminalHost.ID) -> String?
    func setPassword(_ password: String?, for hostID: TerminalHost.ID) throws
    func setPrivateKey(_ privateKey: String?, for hostID: TerminalHost.ID) throws
}

extension TerminalCredentialsStoring {
    func sshCredentials(for hostID: TerminalHost.ID) -> TerminalSSHCredentials {
        TerminalSSHCredentials(
            password: password(for: hostID),
            privateKey: privateKey(for: hostID)
        )
    }

    func setSSHCredentials(_ credentials: TerminalSSHCredentials, for hostID: TerminalHost.ID) throws {
        let normalized = credentials.normalized
        try setPassword(normalized.password, for: hostID)
        try setPrivateKey(normalized.privateKey, for: hostID)
    }
}

final class TerminalKeychainStore: TerminalCredentialsStoring {
    private let passwordService = "dev.cmux.app.terminal.password"
    private let privateKeyService = "dev.cmux.app.terminal.private-key"

    func password(for hostID: TerminalHost.ID) -> String? {
        stringValue(for: hostID, service: passwordService)
    }

    func privateKey(for hostID: TerminalHost.ID) -> String? {
        stringValue(for: hostID, service: privateKeyService)
    }

    func setPassword(_ password: String?, for hostID: TerminalHost.ID) throws {
        try setStringValue(password, for: hostID, service: passwordService)
    }

    func setPrivateKey(_ privateKey: String?, for hostID: TerminalHost.ID) throws {
        try setStringValue(privateKey, for: hostID, service: privateKeyService)
    }

    private func stringValue(for hostID: TerminalHost.ID, service: String) -> String? {
        let query = baseQuery(hostID: hostID, service: service)
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    private func setStringValue(_ value: String?, for hostID: TerminalHost.ID, service: String) throws {
        let query = baseQuery(hostID: hostID, service: service)
        if let value, !value.isEmpty {
            let data = Data(value.utf8)
            let attributes: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if updateStatus == errSecItemNotFound {
                var insertQuery = query
                insertQuery[kSecValueData as String] = data
                let insertStatus = SecItemAdd(insertQuery as CFDictionary, nil)
                guard insertStatus == errSecSuccess else {
                    throw TerminalKeychainError.unhandledStatus(insertStatus)
                }
                return
            }

            guard updateStatus == errSecSuccess else {
                throw TerminalKeychainError.unhandledStatus(updateStatus)
            }
            return
        }

        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw TerminalKeychainError.unhandledStatus(deleteStatus)
        }
    }

    private func baseQuery(hostID: TerminalHost.ID, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
    }
}

enum TerminalKeychainError: Error {
    case unhandledStatus(OSStatus)
}

final class InMemoryTerminalSnapshotStore: TerminalSnapshotPersisting {
    private var snapshot: TerminalStoreSnapshot

    init(snapshot: TerminalStoreSnapshot = .seed()) {
        self.snapshot = snapshot
    }

    func load() -> TerminalStoreSnapshot {
        snapshot
    }

    func save(_ snapshot: TerminalStoreSnapshot) throws {
        self.snapshot = snapshot
    }
}

final class InMemoryTerminalCredentialsStore: TerminalCredentialsStoring {
    private var passwords: [TerminalHost.ID: String]
    private var privateKeys: [TerminalHost.ID: String]

    init(
        passwords: [TerminalHost.ID: String] = [:],
        privateKeys: [TerminalHost.ID: String] = [:]
    ) {
        self.passwords = passwords
        self.privateKeys = privateKeys
    }

    func password(for hostID: TerminalHost.ID) -> String? {
        passwords[hostID]
    }

    func privateKey(for hostID: TerminalHost.ID) -> String? {
        privateKeys[hostID]
    }

    func setPassword(_ password: String?, for hostID: TerminalHost.ID) throws {
        passwords[hostID] = password
    }

    func setPrivateKey(_ privateKey: String?, for hostID: TerminalHost.ID) throws {
        privateKeys[hostID] = privateKey
    }
}

extension TerminalWorkspace {
    func matches(query: String, host: TerminalHost) -> Bool {
        title.localizedLowercase.contains(query) ||
            preview.localizedLowercase.contains(query) ||
            (backendMetadata?.preview?.localizedLowercase.contains(query) ?? false) ||
            host.name.localizedLowercase.contains(query) ||
            host.hostname.localizedLowercase.contains(query)
    }
}

extension UUID {
    var terminalShortID: String {
        uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
    }
}

private enum TerminalModelStrings {
    static let setupRequiredSubtitle = String(
        localized: "terminal.host.setup_required",
        defaultValue: "SSH setup required"
    )
    static let seedHostName = String(
        localized: "terminal.seed.mac_mini",
        defaultValue: "Mac Mini"
    )
}
