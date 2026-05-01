import Foundation
import OSLog

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "terminal.ticket")

struct TerminalDaemonTicketRequest: Encodable, Hashable, Sendable {
    var serverID: String
    var teamID: String?
    var sessionID: String?
    var attachmentID: String?
    var capabilities: [String]

    init(
        serverID: String,
        teamID: String? = nil,
        sessionID: String? = nil,
        attachmentID: String? = nil,
        capabilities: [String] = ["session.attach"]
    ) {
        self.serverID = serverID
        self.teamID = teamID
        self.sessionID = sessionID
        self.attachmentID = attachmentID
        self.capabilities = capabilities.sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case serverID = "server_id"
        case teamID = "team_id"
        case sessionID = "session_id"
        case attachmentID = "attachment_id"
        case capabilities
    }
}

struct TerminalDaemonTicket: Decodable, Equatable, Sendable {
    var ticket: String
    var directURL: URL
    var directTLSPins: [String]
    var sessionID: String
    var attachmentID: String
    var expiresAt: Date

    init(
        ticket: String,
        directURL: URL,
        directTLSPins: [String] = [],
        sessionID: String,
        attachmentID: String,
        expiresAt: Date
    ) {
        self.ticket = ticket
        self.directURL = directURL
        self.directTLSPins = directTLSPins.normalizedTerminalPins
        self.sessionID = sessionID
        self.attachmentID = attachmentID
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case ticket
        case directURL = "direct_url"
        case directTLSPins = "direct_tls_pins"
        case sessionID = "session_id"
        case attachmentID = "attachment_id"
        case expiresAt = "expires_at"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ticket = try container.decode(String.self, forKey: .ticket)
        directURL = try container.decode(URL.self, forKey: .directURL)
        directTLSPins = try container.decodeIfPresent([String].self, forKey: .directTLSPins)?
            .normalizedTerminalPins ?? []
        sessionID = try container.decode(String.self, forKey: .sessionID)
        attachmentID = try container.decode(String.self, forKey: .attachmentID)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
    }
}

enum TerminalDaemonTicketServiceError: Error {
    case invalidResponse
    case httpError(Int, String?)
}

protocol TerminalDaemonTicketProviding: Sendable {
    func fetchTicket(request payload: TerminalDaemonTicketRequest) async throws -> TerminalDaemonTicket
    func invalidateTicket(request payload: TerminalDaemonTicketRequest)
}

extension TerminalDaemonTicketProviding {
    func invalidateTicket(request payload: TerminalDaemonTicketRequest) {}
}

final class TerminalDaemonTicketService: @unchecked Sendable {
    private let endpoint: URL
    private let session: URLSession
    private let tokenProvider: @Sendable () async throws -> String
    private let nowProvider: @Sendable () -> Date
    private let refreshLeeway: TimeInterval
    private let cacheLock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private var cachedTickets: [TerminalDaemonTicketRequest: TerminalDaemonTicket] = [:]

    init(
        endpoint: URL = URL(string: Environment.current.apiBaseURL + "/api/daemon-ticket")!,
        session: URLSession = .shared,
        tokenProvider: @escaping @Sendable () async throws -> String = { try await TerminalDaemonTicketService.liveAccessToken() },
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        refreshLeeway: TimeInterval = 30
    ) {
        self.endpoint = endpoint
        self.session = session
        self.tokenProvider = tokenProvider
        self.nowProvider = nowProvider
        self.refreshLeeway = refreshLeeway
    }

    func fetchTicket(request payload: TerminalDaemonTicketRequest) async throws -> TerminalDaemonTicket {
        if let cachedTicket = cachedTicket(for: payload) {
            log.debug("Returning cached ticket")
            return cachedTicket
        }

        log.debug("Fetching ticket from \(self.endpoint.absoluteString, privacy: .public)")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token: String
        do {
            token = try await tokenProvider()
            log.debug("Got auth token (\(token.count, privacy: .public) chars)")
        } catch {
            log.error("Failed to get auth token: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
            log.debug("Got response type=\(String(describing: type(of: response)), privacy: .public) dataLen=\(data.count, privacy: .public)")
        } catch {
            log.error("Network request failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            log.error("Response is not HTTPURLResponse, throwing invalidResponse")
            throw TerminalDaemonTicketServiceError.invalidResponse
        }
        log.debug("HTTP status=\(httpResponse.statusCode, privacy: .public)")
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let errMsg = parseErrorMessage(from: data)
            log.error("HTTP error \(httpResponse.statusCode, privacy: .public): \(errMsg ?? "nil", privacy: .public)")
            throw TerminalDaemonTicketServiceError.httpError(httpResponse.statusCode, errMsg)
        }

        let ticket = try decoder.decode(TerminalDaemonTicket.self, from: data)
        cache(ticket, for: payload)
        log.debug("Ticket decoded, directURL=\(ticket.directURL, privacy: .public)")
        return ticket
    }

    @MainActor
    private static func liveAccessToken() async throws -> String {
        try await AuthManager.shared.getAccessToken()
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = payload["error"] as? String, !error.isEmpty {
                return error
            }
            if let message = payload["message"] as? String, !message.isEmpty {
                return message
            }
        }
        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        return nil
    }

    private func cachedTicket(for request: TerminalDaemonTicketRequest) -> TerminalDaemonTicket? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard let ticket = cachedTickets[request] else { return nil }
        guard ticket.expiresAt.timeIntervalSince(nowProvider()) > refreshLeeway else {
            cachedTickets.removeValue(forKey: request)
            return nil
        }
        return ticket
    }

    private func cache(_ ticket: TerminalDaemonTicket, for request: TerminalDaemonTicketRequest) {
        cacheLock.lock()
        cachedTickets[request] = ticket
        cacheLock.unlock()
    }
}

extension TerminalDaemonTicketService: TerminalDaemonTicketProviding {}

extension TerminalDaemonTicketService {
    func invalidateTicket(request payload: TerminalDaemonTicketRequest) {
        cacheLock.lock()
        cachedTickets.removeValue(forKey: payload)
        cacheLock.unlock()
    }
}
