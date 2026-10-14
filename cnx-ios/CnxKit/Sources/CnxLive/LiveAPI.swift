import Foundation

/// The `cnx-ios-api` HTTP surface the app uses (PROTOCOL.md "HTTP").
public struct LiveAPI: Sendable {
    public let baseURL: URL
    /// A Stack access token; `true` forces a refresh after a 401.
    let accessToken: @Sendable (_ forceRefresh: Bool) async throws -> String
    let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared, accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String) {
        self.baseURL = baseURL
        self.session = session
        self.accessToken = accessToken
    }

    /// A Mac as `GET /v1/teams/:id/macs` and the signaling `hello` / `presence` frames report it.
    public struct Mac: Codable, Hashable, Sendable {
        public var deviceId: String
        public var name: String
        public var online: Bool
        public var lastSeenAt: String?
        public var ownerUserId: String?
        /// The Mac's team (or personal space); only `GET /v1/me/macs` sends it.
        public var teamId: String?

        public init(deviceId: String, name: String, online: Bool, lastSeenAt: String? = nil, ownerUserId: String? = nil, teamId: String? = nil) {
            self.deviceId = deviceId
            self.name = name
            self.online = online
            self.lastSeenAt = lastSeenAt
            self.ownerUserId = ownerUserId
            self.teamId = teamId
        }

        public var lastSeenDate: Date? { lastSeenAt.flatMap(LiveAPI.parseDate) }
    }

    public struct Prefs: Codable, Hashable, Sendable {
        public var color: String?
        public var emoji: String?

        public init(color: String?, emoji: String?) {
            self.color = color
            self.emoji = emoji
        }
    }

    /// `{"error":{"code","message"}}` or a transport failure.
    public struct Failure: Error, Equatable, Sendable {
        public var status: Int
        public var code: String
        public var message: String
    }

    /// `POST /v1/devices` (upsert).
    public func registerDevice(id: String, kind: String, name: String, teamID: String) async throws {
        let body: [String: Any] = ["deviceId": id, "kind": kind, "name": name, "teamId": teamID]
        _ = try await call("POST", "v1/devices", body: body)
    }

    /// `GET /v1/teams/:id/macs`.
    public func macs(teamID: String) async throws -> [Mac] {
        struct Reply: Decodable { var macs: [Mac] }
        return try JSONDecoder().decode(Reply.self, from: try await call("GET", "v1/teams/\(teamID)/macs")).macs
    }

    /// `GET /v1/me/macs`: the account's own Macs in every team and the personal space.
    public func myMacs() async throws -> [Mac] {
        struct Reply: Decodable { var macs: [Mac] }
        return try JSONDecoder().decode(Reply.self, from: try await call("GET", "v1/me/macs")).macs
    }

    /// `GET /v1/teams/:id/prefs`.
    public func prefs(teamID: String) async throws -> Prefs {
        try JSONDecoder().decode(Prefs.self, from: try await call("GET", "v1/teams/\(teamID)/prefs"))
    }

    /// `PUT /v1/teams/:id/prefs`. A nil emoji clears it.
    public func putPrefs(teamID: String, color: String, emoji: String?) async throws {
        let body: [String: Any] = ["color": color, "emoji": emoji ?? NSNull()]
        _ = try await call("PUT", "v1/teams/\(teamID)/prefs", body: body)
    }

    /// `POST /v1/teams/:id/invites {email}`: Stack emails the invitation.
    public func invite(teamID: String, email: String) async throws {
        _ = try await call("POST", "v1/teams/\(teamID)/invites", body: ["email": email])
    }

    /// The signaling WebSocket request for `deviceID` (bearer header, subprotocol `cnx.v1`).
    public func signalRequest(teamID: String, deviceID: String) async throws -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: "v1/teams/\(teamID)/signal"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.queryItems = [URLQueryItem(name: "deviceId", value: deviceID)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await accessToken(false))", forHTTPHeaderField: "Authorization")
        request.setValue("cnx.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        return request
    }

    func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 15
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        // A rejected token (expired while the app slept) is refreshed once.
        for forceRefresh in [false, true] {
            request.setValue("Bearer \(try await accessToken(forceRefresh))", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, !forceRefresh { continue }
            guard (200..<300).contains(status) else { throw Self.failure(status: status, data: data) }
            return data
        }
        throw Failure(status: 401, code: "unauthorized", message: "token refresh failed")
    }

    static func failure(status: Int, data: Data) -> Failure {
        struct Envelope: Decodable {
            struct Body: Decodable { var code: String; var message: String }
            var error: Body
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            return Failure(status: status, code: envelope.error.code, message: envelope.error.message)
        }
        return Failure(status: status, code: "http_\(status)", message: String(decoding: data.prefix(200), as: UTF8.self))
    }

    static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

/// Signaling frames the app reads (PROTOCOL.md "Signaling WebSocket").
public enum SignalFrame: Equatable, Sendable {
    case hello(you: String, macs: [LiveAPI.Mac])
    case presence(LiveAPI.Mac)
    case error(code: String, message: String)
    case other

    public static func parse(_ data: Data) -> SignalFrame? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        let decoder = JSONDecoder()
        switch type {
        case "hello":
            guard let macs = object["macs"], let raw = try? JSONSerialization.data(withJSONObject: macs),
                  let list = try? decoder.decode([LiveAPI.Mac].self, from: raw) else { return nil }
            return .hello(you: object["you"] as? String ?? "", macs: list)
        case "presence":
            guard let mac = object["mac"], let raw = try? JSONSerialization.data(withJSONObject: mac),
                  let value = try? decoder.decode(LiveAPI.Mac.self, from: raw) else { return nil }
            return .presence(value)
        case "error":
            return .error(code: object["code"] as? String ?? "error", message: object["message"] as? String ?? "")
        default:
            return .other
        }
    }
}
