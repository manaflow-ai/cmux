import Foundation

enum MobilePushEnvironment: String, Codable, Equatable, Sendable {
    case development
    case production
}

struct MobilePushRegisterRequest: Encodable, Equatable, Sendable {
    let token: String
    let environment: MobilePushEnvironment
    let platform: String
    let bundleId: String
    let deviceId: String?
}

struct MobilePushRemoveRequest: Encodable, Equatable, Sendable {
    let token: String
}

struct MobilePushTestRequest: Encodable, Equatable, Sendable {
    let title: String
    let body: String
}

struct MobilePushTestResponse: Decodable, Equatable, Sendable {
    let scheduledCount: Int
}

struct MobileMarkReadRequest: Encodable, Equatable, Sendable {
    let teamSlugOrId: String
    let workspaceId: String
    let latestEventSeq: Int?
}

struct MobileOKResponse: Decodable, Equatable, Sendable {
    let ok: Bool
}

struct MobileAcceptedResponse: Decodable, Equatable, Sendable {
    let accepted: Bool
}

enum MobileRouteClientError: Error {
    case invalidResponse
    case httpError(Int, String?)
}

@MainActor
final class MobileAuthenticatedRouteTransport {
    private let baseURL: URL
    private let session: URLSession
    private let authManager: AuthManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        baseURL: URL = URL(string: Environment.current.apiBaseURL)!,
        session: URLSession = .shared,
        authManager: AuthManager? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.authManager = authManager ?? AuthManager.shared
    }

    var isAuthenticated: Bool {
        authManager.isAuthenticated
    }

    func send<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request,
        responseType: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await authManager.getAccessToken())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MobileRouteClientError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw MobileRouteClientError.httpError(
                httpResponse.statusCode,
                Self.parseErrorMessage(from: data)
            )
        }

        return try decoder.decode(Response.self, from: data)
    }

    private static func parseErrorMessage(from data: Data) -> String? {
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
}

@MainActor
final class MobilePushRouteClient {
    private let transport: MobileAuthenticatedRouteTransport

    init(
        baseURL: URL = URL(string: Environment.current.apiBaseURL)!,
        session: URLSession = .shared,
        authManager: AuthManager? = nil
    ) {
        self.transport = MobileAuthenticatedRouteTransport(
            baseURL: baseURL,
            session: session,
            authManager: authManager ?? AuthManager.shared
        )
    }

    var isAuthenticated: Bool {
        transport.isAuthenticated
    }

    func upsertPushToken(
        token: String,
        environment: MobilePushEnvironment,
        platform: String,
        bundleId: String,
        deviceId: String?
    ) async throws {
        _ = try await transport.send(
            path: "api/mobile/push/register",
            body: MobilePushRegisterRequest(
                token: token,
                environment: environment,
                platform: platform,
                bundleId: bundleId,
                deviceId: deviceId
            ),
            responseType: MobileOKResponse.self
        )
    }

    func removePushToken(token: String) async throws {
        _ = try await transport.send(
            path: "api/mobile/push/remove",
            body: MobilePushRemoveRequest(token: token),
            responseType: MobileOKResponse.self
        )
    }

    func sendTestPush(title: String, body: String) async throws -> MobilePushTestResponse {
        try await transport.send(
            path: "api/mobile/push/test",
            body: MobilePushTestRequest(title: title, body: body),
            responseType: MobilePushTestResponse.self
        )
    }
}

@MainActor
final class MobileWorkspaceReadRouteClient: TerminalRemoteWorkspaceReadMarking {
    private let transport: MobileAuthenticatedRouteTransport

    init(
        baseURL: URL = URL(string: Environment.current.apiBaseURL)!,
        session: URLSession = .shared,
        authManager: AuthManager? = nil
    ) {
        self.transport = MobileAuthenticatedRouteTransport(
            baseURL: baseURL,
            session: session,
            authManager: authManager ?? AuthManager.shared
        )
    }

    func markRead(item: UnifiedInboxItem) async throws {
        guard let teamID = item.teamID,
              let workspaceID = item.workspaceID else {
            return
        }

        _ = try await transport.send(
            path: "api/mobile/workspaces/mark-read",
            body: MobileMarkReadRequest(
                teamSlugOrId: teamID,
                workspaceId: workspaceID,
                latestEventSeq: item.latestEventSeq
            ),
            responseType: MobileOKResponse.self
        )
    }
}
