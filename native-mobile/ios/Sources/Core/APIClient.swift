import Foundation

/// The cmux-next native backend (Cloudflare Worker `cmux-next-native`).
/// Plain REST over URLSession; signaling sockets are opened by the link.
struct APIClient: Sendable {
    struct User: Codable, Sendable, Hashable {
        var id: String
        var email: String?
        var name: String?
    }

    struct Host: Codable, Sendable, Hashable, Identifiable {
        var id: String
        var name: String
        var platform: String?
        var online: Bool?
        var lastSeen: Double?

        enum CodingKeys: String, CodingKey {
            case id, name, platform, online
            case lastSeen = "last_seen"
        }
    }

    struct AuthResponse: Codable, Sendable {
        var user: User
        var sessionToken: String
        enum CodingKeys: String, CodingKey {
            case user
            case sessionToken = "session_token"
        }
    }

    struct APIError: LocalizedError, Sendable {
        var status: Int
        var code: String
        var message: String
        var errorDescription: String? { message }
    }

    private struct ErrorBody: Decodable { var error: String?; var code: String?; var message: String? }

    let base: URL
    var token: String?

    static var configuredBase: URL {
        if let override = UserDefaults.standard.string(forKey: "apiBaseOverride"), let url = URL(string: override) {
            return url
        }
        let value = Bundle.main.object(forInfoDictionaryKey: "CmuxNativeAPIBase") as? String
        return URL(string: value ?? "") ?? URL(string: "https://cmux-next-native.debussy.workers.dev")!
    }

    func signInWithApple(identityToken: String, name: String?) async throws -> AuthResponse {
        try await send("POST", "/v1/auth/apple", body: ["identity_token": identityToken, "name": name ?? ""])
    }

    func signInDev(email: String, secret: String) async throws -> AuthResponse {
        try await send("POST", "/v1/auth/dev", body: ["email": email, "secret": secret])
    }

    func me() async throws -> User {
        struct Me: Codable { var user: User }
        let me: Me = try await send("GET", "/v1/me")
        return me.user
    }

    func hosts() async throws -> [Host] {
        struct Hosts: Codable { var hosts: [Host] }
        let list: Hosts = try await send("GET", "/v1/hosts")
        return list.hosts
    }

    func pair(code: String) async throws -> Host {
        struct Paired: Codable { var host: Host }
        let paired: Paired = try await send("POST", "/v1/pair", body: ["code": code])
        return paired.host
    }

    func unpair(hostID: String) async throws {
        struct Empty: Codable {}
        let _: Empty? = try? await send("DELETE", "/v1/hosts/\(hostID)")
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: [String: String]? = nil) async throws -> T {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 20
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let failure = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw APIError(
                status: status,
                code: failure?.code ?? failure?.error ?? "http_\(status)",
                message: failure?.message ?? failure?.error ?? HTTPURLResponse.localizedString(forStatusCode: status)
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
