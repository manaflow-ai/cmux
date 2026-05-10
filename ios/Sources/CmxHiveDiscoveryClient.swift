import Foundation

struct CmxHiveDiscoverySnapshot: Codable, Equatable, Sendable {
    let nodes: [CmxHiveNode]
    let workspaces: [CmxWorkspace]
}

protocol CmxHiveDiscoveryFetching {
    func fetchHive(
        endpoint: URL,
        stackSession: CmxStackAuthSession,
        teamID: String?
    ) async throws -> CmxHiveDiscoverySnapshot
}

struct CmxHiveTeamsSnapshot: Codable, Equatable, Sendable {
    let teams: [CmxHiveTeam]
    let defaultTeamID: String?
    let selectedTeamID: String?
}

protocol CmxHiveControlFetching {
    func fetchTeams(
        endpoint: URL,
        stackSession: CmxStackAuthSession
    ) async throws -> CmxHiveTeamsSnapshot

    func unlinkNode(
        nodeID: String,
        endpoint: URL,
        stackSession: CmxStackAuthSession,
        teamID: String?
    ) async throws
}

struct CmxHiveDiscoveryClient: CmxHiveDiscoveryFetching {
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func fetchHive(
        endpoint: URL,
        stackSession: CmxStackAuthSession,
        teamID: String?
    ) async throws -> CmxHiveDiscoverySnapshot {
        guard ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""),
              endpoint.host != nil else {
            throw CmxHiveDiscoveryError.invalidEndpoint
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        for (field, value) in stackSession.authorizationHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let teamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            request.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CmxHiveDiscoveryError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw CmxHiveDiscoveryError.badStatus(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(CmxHiveDiscoveryWireSnapshot.self, from: data).snapshot(
                hiveEndpoint: endpoint
            )
        } catch {
            throw CmxHiveDiscoveryError.invalidResponse
        }
    }
}

struct CmxHiveControlClient: CmxHiveControlFetching {
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func fetchTeams(
        endpoint: URL,
        stackSession: CmxStackAuthSession
    ) async throws -> CmxHiveTeamsSnapshot {
        let teamsEndpoint = try CmxHiveEndpointBuilder.endpoint(endpoint, appending: ["teams"])
        var request = URLRequest(url: teamsEndpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        for (field, value) in stackSession.authorizationHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CmxHiveDiscoveryError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw CmxHiveDiscoveryError.badStatus(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(CmxHiveTeamsWireSnapshot.self, from: data).snapshot
        } catch {
            throw CmxHiveDiscoveryError.invalidResponse
        }
    }

    func unlinkNode(
        nodeID: String,
        endpoint: URL,
        stackSession: CmxStackAuthSession,
        teamID: String?
    ) async throws {
        let nodeEndpoint = try CmxHiveEndpointBuilder.endpoint(endpoint, appending: ["nodes", nodeID])
        var request = URLRequest(url: nodeEndpoint)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        for (field, value) in stackSession.authorizationHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let teamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            request.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }

        let (_, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CmxHiveDiscoveryError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw CmxHiveDiscoveryError.badStatus(httpResponse.statusCode)
        }
    }
}

private enum CmxHiveEndpointBuilder {
    static func endpoint(_ endpoint: URL, appending pathComponents: [String]) throws -> URL {
        guard ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""),
              endpoint.host != nil else {
            throw CmxHiveDiscoveryError.invalidEndpoint
        }
        var resolved = endpoint
        for pathComponent in pathComponents {
            resolved.appendPathComponent(pathComponent)
        }
        return resolved
    }
}

enum CmxHiveDiscoveryError: LocalizedError, Equatable {
    case invalidEndpoint
    case badStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return String(localized: "hive.error.invalid_endpoint", defaultValue: "The cmux hive endpoint is invalid.")
        case .badStatus(let status):
            return String(
                format: String(localized: "hive.error.bad_status", defaultValue: "cmux hive discovery failed (%d)."),
                status
            )
        case .invalidResponse:
            return String(localized: "hive.error.invalid_response", defaultValue: "cmux hive discovery returned an invalid response.")
        }
    }
}

private struct CmxHiveDiscoveryWireSnapshot: Decodable {
    let nodes: [CmxHiveDiscoveryWireNode]
    let workspaces: [CmxHiveDiscoveryWireWorkspace]

    private enum CodingKeys: String, CodingKey {
        case nodes
        case workspaces
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try container.decodeIfPresent([CmxHiveDiscoveryWireNode].self, forKey: .nodes) ?? []
        workspaces = try container.decodeIfPresent([CmxHiveDiscoveryWireWorkspace].self, forKey: .workspaces) ?? []
    }

    func snapshot(hiveEndpoint: URL) -> CmxHiveDiscoverySnapshot {
        let decodedNodes = nodes.map { $0.node(hiveEndpoint: hiveEndpoint) }
        let defaultNodeID = nodes.count == 1 ? nodes[0].id.stableUInt64 : nil
        let defaultNodeKey = nodes.count == 1 ? nodes[0].id.stableKey : nil
        var seenWorkspaceIDs = Set<UInt64>()
        var decodedWorkspaces: [CmxWorkspace] = []

        for node in nodes {
            let parentNodeID = node.id.stableUInt64
            let parentNodeKey = node.id.stableKey
            for workspace in node.workspaces {
                let model = workspace.workspace(parentNodeID: parentNodeID, parentNodeKey: parentNodeKey)
                guard seenWorkspaceIDs.insert(model.id).inserted else { continue }
                decodedWorkspaces.append(model)
            }
        }

        for workspace in workspaces {
            let model = workspace.workspace(parentNodeID: defaultNodeID, parentNodeKey: defaultNodeKey)
            guard seenWorkspaceIDs.insert(model.id).inserted else { continue }
            decodedWorkspaces.append(model)
        }

        return CmxHiveDiscoverySnapshot(nodes: decodedNodes, workspaces: decodedWorkspaces)
    }
}

private struct CmxHiveDiscoveryWireNode: Decodable {
    let id: CmxHiveDiscoveryID
    let rawID: String
    let name: String
    let subtitle: String?
    let kind: String?
    let isOnline: Bool
    let restoreState: String?
    let attachTicket: String?
    let attachTicketExpiresAtUnix: UInt64?
    let attach: CmxHiveDiscoveryWireAttach?
    let workspaces: [CmxHiveDiscoveryWireWorkspace]

    func node(hiveEndpoint: URL) -> CmxHiveNode {
        let restoreIsReady = restoreState?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "restoring"
            && restoreState?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "starting"
        let resolvedAttachTicket = attachTicket?.nonEmpty
            ?? attach?.ticket(
                hiveEndpoint: hiveEndpoint,
                node: CmxHiveDiscoveryWireAttachNode(
                    id: rawID,
                    name: name,
                    subtitle: subtitle,
                    kind: kind
                )
            )
        return CmxHiveNode(
            id: id.stableUInt64,
            rawID: rawID,
            name: name,
            subtitle: subtitle?.nonEmpty ?? String(localized: "node.connected.subtitle", defaultValue: "connected"),
            symbolName: CmxHiveNodeFactory.symbolName(for: kind),
            platform: CmxHostPlatform.infer(kind: kind, name: name, subtitle: subtitle),
            isOnline: isOnline && restoreIsReady,
            attachTicket: resolvedAttachTicket,
            attachTicketExpiresAtUnix: attachTicketExpiresAtUnix ?? attach?.expiresAtUnix
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case subtitle
        case kind
        case isOnline = "is_online"
        case online
        case restoreState = "restore_state"
        case attachTicket = "attach_ticket"
        case attachTicketExpiresAtUnix = "attach_ticket_expires_at_unix"
        case attach
        case workspaces
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(CmxHiveDiscoveryID.self, forKey: .id)
        rawID = id.displayString
        name = try container.decode(String.self, forKey: .name)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        isOnline = try container.decodeIfPresent(Bool.self, forKey: .isOnline)
            ?? container.decodeIfPresent(Bool.self, forKey: .online)
            ?? false
        restoreState = try container.decodeIfPresent(String.self, forKey: .restoreState)
        attachTicket = try container.decodeIfPresent(String.self, forKey: .attachTicket)
        attachTicketExpiresAtUnix = try container.decodeIfPresent(UInt64.self, forKey: .attachTicketExpiresAtUnix)
        attach = try container.decodeIfPresent(CmxHiveDiscoveryWireAttach.self, forKey: .attach)
        workspaces = try container.decodeIfPresent([CmxHiveDiscoveryWireWorkspace].self, forKey: .workspaces) ?? []
    }
}

private struct CmxHiveDiscoveryWireAttach: Decodable {
    let endpoint: CmxHiveDiscoveryJSONValue
    let pairingID: String
    let rivetEndpoint: String?
    let stackProjectID: String
    let expiresAtUnix: UInt64

    private enum CodingKeys: String, CodingKey {
        case endpoint
        case pairingID = "pairing_id"
        case rivetEndpoint = "rivet_endpoint"
        case stackProjectID = "stack_project_id"
        case expiresAtUnix = "expires_at_unix"
    }

    func ticket(hiveEndpoint: URL, node: CmxHiveDiscoveryWireAttachNode) -> String? {
        let resolvedRivetEndpoint = rivetEndpoint?.nonEmpty ?? hiveEndpoint.absoluteString
        guard !pairingID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !resolvedRivetEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !stackProjectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              expiresAtUnix > 0 else {
            return nil
        }

        let ticket = CmxHiveDiscoveryWireAttachTicket(
            version: 1,
            alpn: "/cmux/cmx/3",
            endpoint: endpoint,
            auth: CmxHiveDiscoveryWireAttachAuth(
                mode: "rivet_stack",
                pairingID: pairingID,
                rivetEndpoint: resolvedRivetEndpoint,
                stackProjectID: stackProjectID,
                expiresAtUnix: expiresAtUnix
            ),
            node: node
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(ticket) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private struct CmxHiveDiscoveryWireAttachTicket: Encodable {
    let version: Int
    let alpn: String
    let endpoint: CmxHiveDiscoveryJSONValue
    let auth: CmxHiveDiscoveryWireAttachAuth
    let node: CmxHiveDiscoveryWireAttachNode
}

private struct CmxHiveDiscoveryWireAttachAuth: Encodable {
    let mode: String
    let pairingID: String
    let rivetEndpoint: String
    let stackProjectID: String
    let expiresAtUnix: UInt64

    private enum CodingKeys: String, CodingKey {
        case mode
        case pairingID = "pairing_id"
        case rivetEndpoint = "rivet_endpoint"
        case stackProjectID = "stack_project_id"
        case expiresAtUnix = "expires_at_unix"
    }
}

private struct CmxHiveDiscoveryWireAttachNode: Encodable {
    let id: String?
    let name: String
    let subtitle: String?
    let kind: String?
}

private struct CmxHiveDiscoveryWireWorkspace: Decodable {
    let id: CmxHiveDiscoveryID
    let nodeID: CmxHiveDiscoveryID?
    let workspaceKey: CmxHiveDiscoveryID?
    let localWorkspaceID: CmxHiveDiscoveryID?
    let title: String
    let preview: String?
    let lastActivity: Date?
    let unread: Bool
    let pinned: Bool
    let spaces: [CmxHiveDiscoveryWireSpace]

    private enum CodingKeys: String, CodingKey {
        case id
        case nodeID = "node_id"
        case workspaceKey = "workspace_key"
        case localWorkspaceID = "local_workspace_id"
        case title
        case preview
        case lastActivityUnix = "last_activity_unix"
        case lastActivityMs = "last_activity_ms"
        case lastActivityISO8601 = "last_activity"
        case updatedAtUnix = "updated_at_unix"
        case updatedAtMs = "updated_at_ms"
        case updatedAtISO8601 = "updated_at"
        case unread
        case pinned
        case spaces
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(CmxHiveDiscoveryID.self, forKey: .id)
        nodeID = try container.decodeIfPresent(CmxHiveDiscoveryID.self, forKey: .nodeID)
        workspaceKey = try container.decodeIfPresent(CmxHiveDiscoveryID.self, forKey: .workspaceKey)
        localWorkspaceID = try container.decodeIfPresent(CmxHiveDiscoveryID.self, forKey: .localWorkspaceID)
        title = try container.decode(String.self, forKey: .title)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        unread = try container.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        spaces = try container.decodeIfPresent([CmxHiveDiscoveryWireSpace].self, forKey: .spaces) ?? []

        if let unix = try container.decodeIfPresent(Double.self, forKey: .lastActivityUnix) {
            lastActivity = Date(timeIntervalSince1970: unix)
        } else if let milliseconds = try container.decodeIfPresent(Double.self, forKey: .lastActivityMs) {
            lastActivity = Date(timeIntervalSince1970: milliseconds / 1_000)
        } else if let iso8601 = try container.decodeIfPresent(String.self, forKey: .lastActivityISO8601) {
            lastActivity = ISO8601DateFormatter().date(from: iso8601)
        } else if let unix = try container.decodeIfPresent(Double.self, forKey: .updatedAtUnix) {
            lastActivity = Date(timeIntervalSince1970: unix)
        } else if let milliseconds = try container.decodeIfPresent(Double.self, forKey: .updatedAtMs) {
            lastActivity = Date(timeIntervalSince1970: milliseconds / 1_000)
        } else if let iso8601 = try container.decodeIfPresent(String.self, forKey: .updatedAtISO8601) {
            lastActivity = ISO8601DateFormatter().date(from: iso8601)
        } else {
            lastActivity = nil
        }
    }

    func workspace(parentNodeID: UInt64?, parentNodeKey: String?) -> CmxWorkspace {
        let resolvedNodeID = nodeID?.stableUInt64 ?? parentNodeID ?? 0
        let modelKey = workspaceModelKey(parentNodeKey: parentNodeKey)
        let modelID = workspaceModelID(parentNodeKey: parentNodeKey)
        let resolvedSpaces = spaces.map { $0.space(parentWorkspaceKey: modelKey) }
        let terminalCount = resolvedSpaces.reduce(0) { $0 + $1.terminals.count }
        return CmxWorkspace(
            id: modelID,
            nodeID: resolvedNodeID,
            title: title,
            preview: preview?.nonEmpty ?? String(
                format: String(localized: "workspace.row.detail", defaultValue: "%d spaces, %d terminals"),
                resolvedSpaces.count,
                terminalCount
            ),
            lastActivity: lastActivity ?? Date(),
            unread: unread,
            pinned: pinned,
            spaces: resolvedSpaces,
            localWorkspaceID: localWorkspaceID?.displayString.nonEmpty ?? id.displayString.nonEmpty
        )
    }

    private func workspaceModelID(parentNodeKey: String?) -> UInt64 {
        if let workspaceKey {
            return workspaceKey.stableUInt64
        }
        guard nodeID != nil || parentNodeKey != nil else {
            return id.stableUInt64
        }
        return CmxStableID.uint64(for: workspaceModelKey(parentNodeKey: parentNodeKey))
    }

    private func workspaceModelKey(parentNodeKey: String?) -> String {
        if let workspaceKey {
            return workspaceKey.stableKey
        }
        let localKey = localWorkspaceID?.stableKey ?? id.stableKey
        guard let nodeKey = nodeID?.stableKey ?? parentNodeKey else {
            return localKey
        }
        return "\(nodeKey):\(localKey)"
    }
}

private struct CmxHiveDiscoveryWireSpace: Decodable {
    let id: CmxHiveDiscoveryID
    let title: String
    let terminals: [CmxHiveDiscoveryWireTerminal]

    func space(parentWorkspaceKey: String) -> CmxSpace {
        let modelKey = "\(parentWorkspaceKey):space:\(id.stableKey)"
        return CmxSpace(
            id: CmxStableID.uint64(for: modelKey),
            title: title,
            terminals: terminals.map { $0.terminal(parentSpaceKey: modelKey) }
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case terminals
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(CmxHiveDiscoveryID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        terminals = try container.decodeIfPresent([CmxHiveDiscoveryWireTerminal].self, forKey: .terminals) ?? []
    }
}

private struct CmxHiveDiscoveryWireTerminal: Decodable {
    let id: CmxHiveDiscoveryID
    let title: String
    let cols: Int
    let rows: Int
    let outputRows: [String]

    func terminal(parentSpaceKey: String) -> CmxTerminal {
        CmxTerminal(
            id: CmxStableID.uint64(for: "\(parentSpaceKey):terminal:\(id.stableKey)"),
            title: title,
            size: CmxTerminalSize(cols: max(1, cols), rows: max(1, rows)),
            rows: outputRows
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case cols
        case columns
        case rows
        case outputRows = "output_rows"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(CmxHiveDiscoveryID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        cols = try container.decodeIfPresent(Int.self, forKey: .cols)
            ?? container.decodeIfPresent(Int.self, forKey: .columns)
            ?? CmxTerminalSize.phoneDefault.cols
        rows = try container.decodeIfPresent(Int.self, forKey: .rows)
            ?? CmxTerminalSize.phoneDefault.rows
        outputRows = try container.decodeIfPresent([String].self, forKey: .outputRows) ?? []
    }
}

private enum CmxHiveDiscoveryID: Decodable, Hashable {
    case number(UInt64)
    case string(String)

    var stableUInt64: UInt64 {
        switch self {
        case .number(let value):
            return value == 0 ? CmxStableID.uint64(for: "0") : value
        case .string(let value):
            if let parsed = UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines)), parsed != 0 {
                return parsed
            }
            return CmxStableID.uint64(for: value)
        }
    }

    var stableKey: String {
        switch self {
        case .number(let value):
            return "n:\(value)"
        case .string(let value):
            return "s:\(value.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    var displayString: String {
        switch self {
        case .number(let value):
            return "\(value)"
        case .string(let value):
            return value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(UInt64.self) {
            self = .number(value)
            return
        }
        self = .string(try container.decode(String.self))
    }
}

private enum CmxHiveDiscoveryJSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: CmxHiveDiscoveryJSONValue])
    case array([CmxHiveDiscoveryJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CmxHiveDiscoveryJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: CmxHiveDiscoveryJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

private struct CmxHiveTeamsWireSnapshot: Decodable {
    let teams: [CmxHiveTeamWire]
    let defaultTeamID: String?
    let selectedTeamID: String?

    var snapshot: CmxHiveTeamsSnapshot {
        CmxHiveTeamsSnapshot(
            teams: teams.map(\.team),
            defaultTeamID: defaultTeamID?.nonEmpty,
            selectedTeamID: selectedTeamID?.nonEmpty
        )
    }

    private enum CodingKeys: String, CodingKey {
        case teams
        case defaultTeamID = "default_team_id"
        case selectedTeamID = "selected_team_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        teams = try container.decodeIfPresent([CmxHiveTeamWire].self, forKey: .teams) ?? []
        defaultTeamID = try container.decodeIfPresent(String.self, forKey: .defaultTeamID)
        selectedTeamID = try container.decodeIfPresent(String.self, forKey: .selectedTeamID)
    }
}

private struct CmxHiveTeamWire: Decodable {
    let id: String
    let displayName: String
    let isPersonal: Bool

    var team: CmxHiveTeam {
        CmxHiveTeam(
            id: id,
            displayName: displayName.nonEmpty ?? id,
            isPersonal: isPersonal
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case isPersonal = "is_personal"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? id
        isPersonal = try container.decodeIfPresent(Bool.self, forKey: .isPersonal) ?? false
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
