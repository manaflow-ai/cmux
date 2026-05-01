import Foundation

struct TerminalPane: Codable, Equatable, Sendable, Identifiable {
    let id: String
    var sessionID: String?
    var title: String
    var directory: String
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
    var pinned: Bool
    var panes: [TerminalPane] = []
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
        pinned: Bool = false,
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
        self.pinned = pinned
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ID.self, forKey: .id)
        hostID = try container.decode(TerminalHost.ID.self, forKey: .hostID)
        title = try container.decode(String.self, forKey: .title)
        tmuxSessionName = try container.decode(String.self, forKey: .tmuxSessionName)
        preview = try container.decode(String.self, forKey: .preview)
        lastActivity = try container.decode(Date.self, forKey: .lastActivity)
        unread = try container.decode(Bool.self, forKey: .unread)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        phase = try container.decode(TerminalConnectionPhase.self, forKey: .phase)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        remoteWorkspaceID = try container.decodeIfPresent(String.self, forKey: .remoteWorkspaceID)
        backendIdentity = try container.decodeIfPresent(TerminalWorkspaceBackendIdentity.self, forKey: .backendIdentity)
        backendMetadata = try container.decodeIfPresent(TerminalWorkspaceBackendMetadata.self, forKey: .backendMetadata)
        remoteDaemonResumeState = try container.decodeIfPresent(TerminalRemoteDaemonResumeState.self, forKey: .remoteDaemonResumeState)
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

struct TerminalWorkspaceDeviceSection: Identifiable, Equatable {
    let host: TerminalHost
    let workspaces: [TerminalWorkspace]

    var id: TerminalHost.ID { host.id }

    var title: String {
        host.name
    }

    var subtitle: String? {
        let hostname = host.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostname.isEmpty else { return nil }
        guard hostname.caseInsensitiveCompare(host.name) != .orderedSame else { return nil }
        return hostname
    }
}

enum TerminalWorkspaceDeviceSectionBuilder {
    static func makeSections(
        workspaces: [TerminalWorkspace],
        hosts: [TerminalHost],
        query: String
    ) -> [TerminalWorkspaceDeviceSection] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let hostsByID = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        let filtered = workspaces
            .filter { workspace in
                guard let host = hostsByID[workspace.hostID] else { return false }
                guard !normalizedQuery.isEmpty else { return true }
                return workspace.matches(query: normalizedQuery, host: host)
            }
            .sorted { $0.lastActivity > $1.lastActivity }

        var orderedHostIDs: [TerminalHost.ID] = []
        var grouped: [TerminalHost.ID: [TerminalWorkspace]] = [:]

        for workspace in filtered {
            if grouped[workspace.hostID] == nil {
                orderedHostIDs.append(workspace.hostID)
            }
            grouped[workspace.hostID, default: []].append(workspace)
        }

        return orderedHostIDs.compactMap { hostID in
            guard let host = hostsByID[hostID],
                  let workspaces = grouped[hostID],
                  !workspaces.isEmpty else {
                return nil
            }
            return TerminalWorkspaceDeviceSection(
                host: host,
                workspaces: workspaces
            )
        }
    }
}

struct UnifiedInboxWorkspaceDeviceSection: Identifiable, Equatable {
    let machineID: String
    let title: String
    let subtitle: String?
    let items: [UnifiedInboxItem]

    var id: String { machineID }
}

enum UnifiedInboxWorkspaceDeviceSectionBuilder {
    static func makeSections(
        items: [UnifiedInboxItem]
    ) -> [UnifiedInboxWorkspaceDeviceSection] {
        let filtered = items
            .filter { $0.kind == .workspace }
            .sorted { $0.sortDate > $1.sortDate }

        var orderedMachineIDs: [String] = []
        var grouped: [String: [UnifiedInboxItem]] = [:]

        for item in filtered {
            let machineID = normalizedMachineID(for: item)
            if grouped[machineID] == nil {
                orderedMachineIDs.append(machineID)
            }
            grouped[machineID, default: []].append(item)
        }

        return orderedMachineIDs.compactMap { machineID in
            guard let items = grouped[machineID],
                  let first = items.first else {
                return nil
            }

            return UnifiedInboxWorkspaceDeviceSection(
                machineID: machineID,
                title: displayTitle(for: first, machineID: machineID),
                subtitle: subtitle(for: first, machineID: machineID),
                items: items
            )
        }
    }

    private static func normalizedMachineID(for item: UnifiedInboxItem) -> String {
        let machineID = item.machineID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let machineID, !machineID.isEmpty else {
            return item.id
        }
        return machineID
    }

    private static func displayTitle(for item: UnifiedInboxItem, machineID: String) -> String {
        let label = item.accessoryLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let label, !label.isEmpty else { return machineID }
        return label
    }

    private static func subtitle(for item: UnifiedInboxItem, machineID: String) -> String? {
        let candidates = [
            item.tailscaleHostname?.trimmingCharacters(in: .whitespacesAndNewlines),
            item.tailscaleIPs.first?.trimmingCharacters(in: .whitespacesAndNewlines),
            machineID,
        ]

        let title = displayTitle(for: item, machineID: machineID)
        for candidate in candidates {
            guard let candidate, !candidate.isEmpty else { continue }
            guard candidate.caseInsensitiveCompare(title) != .orderedSame else { continue }
            return candidate
        }

        return nil
    }
}

extension UUID {
    var terminalShortID: String {
        uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
    }
}
