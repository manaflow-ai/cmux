import Foundation

struct CmxHiveDiscoverySnapshot: Equatable, Sendable {
    let nodes: [CmxHiveNode]
    let workspaces: [CmxWorkspace]
}

protocol CmxHiveDiscoveryFetching {
    func fetchHive(
        endpoint: URL,
        stackSession: CmxStackAuthSession
    ) async throws -> CmxHiveDiscoverySnapshot
}

struct CmxHiveDiscoveryClient: CmxHiveDiscoveryFetching {
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func fetchHive(
        endpoint: URL,
        stackSession: CmxStackAuthSession
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

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CmxHiveDiscoveryError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw CmxHiveDiscoveryError.badStatus(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(CmxHiveDiscoveryWireSnapshot.self, from: data).snapshot()
        } catch {
            throw CmxHiveDiscoveryError.invalidResponse
        }
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

    func snapshot() -> CmxHiveDiscoverySnapshot {
        let decodedNodes = nodes.map(\.node)
        let defaultNodeID = decodedNodes.count == 1 ? decodedNodes[0].id : nil
        var seenWorkspaceIDs = Set<UInt64>()
        var decodedWorkspaces: [CmxWorkspace] = []

        for node in nodes {
            let parentNodeID = node.id.stableUInt64
            for workspace in node.workspaces {
                let model = workspace.workspace(parentNodeID: parentNodeID)
                guard seenWorkspaceIDs.insert(model.id).inserted else { continue }
                decodedWorkspaces.append(model)
            }
        }

        for workspace in workspaces {
            let model = workspace.workspace(parentNodeID: defaultNodeID)
            guard seenWorkspaceIDs.insert(model.id).inserted else { continue }
            decodedWorkspaces.append(model)
        }

        return CmxHiveDiscoverySnapshot(nodes: decodedNodes, workspaces: decodedWorkspaces)
    }
}

private struct CmxHiveDiscoveryWireNode: Decodable {
    let id: CmxHiveDiscoveryID
    let name: String
    let subtitle: String?
    let kind: String?
    let isOnline: Bool
    let workspaces: [CmxHiveDiscoveryWireWorkspace]

    var node: CmxHiveNode {
        CmxHiveNode(
            id: id.stableUInt64,
            name: name,
            subtitle: subtitle?.nonEmpty ?? String(localized: "node.connected.subtitle", defaultValue: "connected"),
            symbolName: CmxHiveNodeFactory.symbolName(for: kind),
            platform: CmxHostPlatform.infer(kind: kind, name: name, subtitle: subtitle),
            isOnline: isOnline
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case subtitle
        case kind
        case isOnline = "is_online"
        case online
        case workspaces
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(CmxHiveDiscoveryID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        isOnline = try container.decodeIfPresent(Bool.self, forKey: .isOnline)
            ?? container.decodeIfPresent(Bool.self, forKey: .online)
            ?? false
        workspaces = try container.decodeIfPresent([CmxHiveDiscoveryWireWorkspace].self, forKey: .workspaces) ?? []
    }
}

private struct CmxHiveDiscoveryWireWorkspace: Decodable {
    let id: CmxHiveDiscoveryID
    let nodeID: CmxHiveDiscoveryID?
    let title: String
    let preview: String?
    let lastActivity: Date?
    let unread: Bool
    let pinned: Bool
    let spaces: [CmxHiveDiscoveryWireSpace]

    private enum CodingKeys: String, CodingKey {
        case id
        case nodeID = "node_id"
        case title
        case preview
        case lastActivityUnix = "last_activity_unix"
        case lastActivityMs = "last_activity_ms"
        case lastActivityISO8601 = "last_activity"
        case unread
        case pinned
        case spaces
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(CmxHiveDiscoveryID.self, forKey: .id)
        nodeID = try container.decodeIfPresent(CmxHiveDiscoveryID.self, forKey: .nodeID)
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
        } else {
            lastActivity = nil
        }
    }

    func workspace(parentNodeID: UInt64?) -> CmxWorkspace {
        let resolvedNodeID = nodeID?.stableUInt64 ?? parentNodeID ?? 0
        let resolvedSpaces = spaces.map(\.space)
        let terminalCount = resolvedSpaces.reduce(0) { $0 + $1.terminals.count }
        return CmxWorkspace(
            id: id.stableUInt64,
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
            spaces: resolvedSpaces
        )
    }
}

private struct CmxHiveDiscoveryWireSpace: Decodable {
    let id: CmxHiveDiscoveryID
    let title: String
    let terminals: [CmxHiveDiscoveryWireTerminal]

    var space: CmxSpace {
        CmxSpace(id: id.stableUInt64, title: title, terminals: terminals.map(\.terminal))
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

    var terminal: CmxTerminal {
        CmxTerminal(
            id: id.stableUInt64,
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

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(UInt64.self) {
            self = .number(value)
            return
        }
        self = .string(try container.decode(String.self))
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
