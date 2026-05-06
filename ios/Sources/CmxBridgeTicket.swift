import Foundation

private let cmxSupportedBridgeALPNs: Set<String> = ["/cmux/cmx/3", "/cmux/native/1"]

struct CmxBridgeTicket: Decodable, Equatable {
    let version: Int
    let alpn: String
    let endpoint: CmxEndpointAddr
    let auth: CmxBridgeTicketAuth?
    let node: CmxBridgeTicketNode?

    var webSocketURL: URL? {
        endpoint.addrs.lazy.compactMap(\.webSocketURL).first
    }

    var webSocketToken: String? {
        guard let url = webSocketURL,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let item = components.queryItems?.first(where: { $0.name == "token" || $0.name == "access_token" })
        else { return nil }
        return item.value
    }
}

struct CmxBridgeTicketNode: Decodable, Equatable {
    let id: String?
    let name: String
    let subtitle: String?
    let kind: String?
}

struct CmxEndpointAddr: Decodable, Equatable {
    let id: String
    let addrs: [CmxTransportAddr]
}

enum CmxBridgeTicketAuth: Decodable, Equatable {
    case direct
    case rivetStack(pairingID: String, rivetEndpoint: String, stackProjectID: String, expiresAtUnix: UInt64)
    case unknown(String)

    var pairingID: String? {
        guard case .rivetStack(let pairingID, _, _, _) = self else { return nil }
        return pairingID
    }

    var requiresStackSession: Bool {
        guard case .rivetStack = self else { return false }
        return true
    }

    var label: String {
        switch self {
        case .direct:
            return String(localized: "ticket.auth.direct", defaultValue: "direct development ticket")
        case .rivetStack(let pairingID, _, _, _):
            return String(
                format: String(localized: "ticket.auth.rivet_stack", defaultValue: "Stack + Rivet pairing %@"),
                pairingID
            )
        case .unknown(let mode):
            return String(
                format: String(localized: "ticket.auth.unknown", defaultValue: "unknown auth %@"),
                mode
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case pairingID = "pairing_id"
        case rivetEndpoint = "rivet_endpoint"
        case stackProjectID = "stack_project_id"
        case expiresAtUnix = "expires_at_unix"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decode(String.self, forKey: .mode)
        switch mode {
        case "direct":
            self = .direct
        case "rivet_stack":
            self = .rivetStack(
                pairingID: try container.decode(String.self, forKey: .pairingID),
                rivetEndpoint: try container.decode(String.self, forKey: .rivetEndpoint),
                stackProjectID: try container.decode(String.self, forKey: .stackProjectID),
                expiresAtUnix: try container.decode(UInt64.self, forKey: .expiresAtUnix)
            )
        default:
            self = .unknown(mode)
        }
    }
}

enum CmxTransportAddr: Equatable, Identifiable {
    case relay(String)
    case ip(String)
    case custom(String)
    case unknown(String)

    var id: String { label }

    var label: String {
        switch self {
        case .relay(let value):
            return String(
                format: String(localized: "ticket.route.relay", defaultValue: "relay:%@"),
                value
            )
        case .ip(let value):
            return String(
                format: String(localized: "ticket.route.ip", defaultValue: "ip:%@"),
                value
            )
        case .custom(let value):
            return String(
                format: String(localized: "ticket.route.custom", defaultValue: "custom:%@"),
                CmxTransportAddr.redactedDisplayValue(value)
            )
        case .unknown(let value):
            return CmxTransportAddr.redactedDisplayValue(value)
        }
    }

    var rawValue: String {
        switch self {
        case .relay(let value), .ip(let value), .custom(let value), .unknown(let value):
            return value
        }
    }

    var webSocketURL: URL? {
        guard var components = URLComponents(string: rawValue),
              components.scheme == "ws" || components.scheme == "wss"
        else { return nil }
        if components.path.isEmpty || components.path == "/" {
            components.path = "/attach"
        }
        return components.url
    }

    private static func redactedDisplayValue(_ value: String) -> String {
        guard var components = URLComponents(string: value),
              components.scheme == "ws" || components.scheme == "wss",
              let queryItems = components.queryItems
        else { return value }
        components.queryItems = queryItems.map { item in
            if item.name == "token" || item.name == "access_token" {
                return URLQueryItem(name: item.name, value: "redacted")
            }
            return item
        }
        return components.string ?? value
    }
}

extension CmxTransportAddr: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let keyed = try? container.decode([String: String].self),
           let first = keyed.first {
            switch first.key {
            case "Relay":
                self = .relay(first.value)
            case "Ip":
                self = .ip(first.value)
            case "Custom":
                self = .custom(first.value)
            default:
                self = .unknown(
                    String(
                        format: String(localized: "ticket.route.keyed_unknown", defaultValue: "%@:%@"),
                        first.key,
                        first.value
                    )
                )
            }
            return
        }

        if let value = try? container.decode(String.self) {
            self = .unknown(value)
            return
        }

        self = .unknown(String(localized: "ticket.route.unknown", defaultValue: "unknown route"))
    }
}

enum CmxBridgeTicketParser {
    static func parse(_ rawTicket: String, now: Date = Date()) throws -> CmxBridgeTicket {
        let trimmed = rawTicket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CmxTicketError.empty
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw CmxTicketError.invalidUTF8
        }
        let ticket: CmxBridgeTicket
        do {
            ticket = try JSONDecoder().decode(CmxBridgeTicket.self, from: data)
        } catch {
            throw CmxTicketError.invalidFormat
        }
        guard ticket.version == 1 else {
            throw CmxTicketError.unsupportedVersion(ticket.version)
        }
        guard cmxSupportedBridgeALPNs.contains(ticket.alpn) else {
            throw CmxTicketError.unsupportedALPN(ticket.alpn)
        }
        try validateAuth(ticket.auth, now: now)
        return ticket
    }

    private static func validateAuth(_ auth: CmxBridgeTicketAuth?, now: Date) throws {
        guard let auth else {
            throw CmxTicketError.missingAuth
        }

        switch auth {
        case .direct:
            return
        case .unknown(let mode):
            throw CmxTicketError.unsupportedAuth(mode)
        case .rivetStack(let pairingID, let rivetEndpoint, let stackProjectID, let expiresAtUnix):
            guard !pairingID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CmxTicketError.missingPairingID
            }
            guard !stackProjectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CmxTicketError.missingStackProjectID
            }
            guard let url = URL(string: rivetEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = url.scheme,
                  ["http", "https"].contains(scheme),
                  url.host != nil else {
                throw CmxTicketError.invalidRivetEndpoint
            }
            guard expiresAtUnix > UInt64(now.timeIntervalSince1970.rounded(.down)) else {
                throw CmxTicketError.expiredPairing
            }
        }
    }
}

enum CmxTicketError: LocalizedError, Equatable {
    case empty
    case invalidUTF8
    case invalidFormat
    case unsupportedVersion(Int)
    case unsupportedALPN(String)
    case missingAuth
    case unsupportedAuth(String)
    case missingPairingID
    case missingStackProjectID
    case invalidRivetEndpoint
    case expiredPairing

    var errorDescription: String? {
        switch self {
        case .empty:
            return String(localized: "ticket.error.empty", defaultValue: "No pairing ticket is available.")
        case .invalidUTF8:
            return String(localized: "ticket.error.utf8", defaultValue: "The ticket is not valid UTF-8.")
        case .invalidFormat:
            return String(localized: "ticket.error.format", defaultValue: "The pairing ticket is not valid.")
        case .unsupportedVersion(let version):
            return String(
                format: String(localized: "ticket.error.version", defaultValue: "Unsupported pairing ticket version %d."),
                version
            )
        case .unsupportedALPN(let alpn):
            return String(
                format: String(localized: "ticket.error.alpn", defaultValue: "Unsupported pairing protocol %@."),
                alpn
            )
        case .missingAuth:
            return String(localized: "ticket.error.auth_missing", defaultValue: "The pairing ticket is missing auth metadata.")
        case .unsupportedAuth(let mode):
            return String(
                format: String(localized: "ticket.error.auth_unsupported", defaultValue: "Unsupported pairing auth mode %@."),
                mode
            )
        case .missingPairingID:
            return String(localized: "ticket.error.pairing_id", defaultValue: "The pairing ticket is missing its Rivet pairing id.")
        case .missingStackProjectID:
            return String(localized: "ticket.error.stack_project_id", defaultValue: "The pairing ticket is missing its Stack project id.")
        case .invalidRivetEndpoint:
            return String(localized: "ticket.error.rivet_endpoint", defaultValue: "The pairing ticket has an invalid Rivet endpoint.")
        case .expiredPairing:
            return String(localized: "ticket.error.pairing_expired", defaultValue: "The pairing ticket has expired.")
        }
    }
}
