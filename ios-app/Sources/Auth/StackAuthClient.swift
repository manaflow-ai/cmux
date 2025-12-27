import Foundation

// Stack Auth REST API Client
// Docs: https://docs.stack-auth.com/rest-api/overview

class StackAuthClient {
    static let shared = StackAuthClient()

    private let projectId: String
    private let publishableClientKey: String
    private let baseURL = "https://api.stack-auth.com/api/v1"

    private init() {
        let env = Environment.current
        self.projectId = env.stackAuthProjectId
        self.publishableClientKey = env.stackAuthPublishableKey
        print("🔐 Stack Auth initialized (\(env.name))")
    }

    private var commonHeaders: [String: String] {
        [
            "Content-Type": "application/json",
            "x-stack-project-id": projectId,
            "x-stack-publishable-client-key": publishableClientKey,
            "x-stack-access-type": "client"
        ]
    }

    // MARK: - Send OTP Code

    struct SendCodeResponse: Codable {
        let nonce: String
    }

    func sendSignInCode(email: String) async throws -> String {
        let url = URL(string: "\(baseURL)/auth/otp/send-sign-in-code")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        commonHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        // callback_url must be whitelisted in Stack Auth
        // Using localhost for dev, cmux.dev for prod
        // Since we use OTP code entry (not magic link click), this is just a placeholder
        let callbackUrl = Environment.current == .development
            ? "http://localhost:3000/auth/callback"
            : "https://cmux.dev/auth/callback"

        let body: [String: Any] = [
            "email": email,
            "callback_url": callbackUrl
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError
        }

        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("Stack Auth error: \(httpResponse.statusCode) - \(errorBody)")
            throw AuthError.serverError(httpResponse.statusCode, errorBody)
        }

        let decoded = try JSONDecoder().decode(SendCodeResponse.self, from: data)
        return decoded.nonce
    }

    // MARK: - Password Sign In (for debugging)

    struct PasswordSignInResponse: Codable {
        let refresh_token: String
        let access_token: String
        let user_id: String
    }

    func signInWithPassword(email: String, password: String) async throws -> PasswordSignInResponse {
        let url = URL(string: "\(baseURL)/auth/password/sign-in")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        commonHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let body = ["email": email, "password": password]
        request.httpBody = try JSONEncoder().encode(body)

        print("🔐 Sending password sign-in request to \(url)")
        let (data, response) = try await URLSession.shared.data(for: request)
        print("🔐 Got response from password sign-in")

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError
        }

        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("Stack Auth password error: \(httpResponse.statusCode) - \(errorBody)")
            throw AuthError.serverError(httpResponse.statusCode, errorBody)
        }

        return try JSONDecoder().decode(PasswordSignInResponse.self, from: data)
    }

    // MARK: - Verify OTP Code

    struct SignInResponse: Codable {
        let refresh_token: String
        let access_token: String
        let is_new_user: Bool?
        let user_id: String
    }

    func signIn(code: String, nonce: String) async throws -> SignInResponse {
        let url = URL(string: "\(baseURL)/auth/otp/sign-in")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        commonHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        // OTP code = 6-digit code + nonce concatenated
        let fullCode = code + nonce

        let body = ["code": fullCode]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError
        }

        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("Stack Auth error: \(httpResponse.statusCode) - \(errorBody)")
            throw AuthError.invalidCode
        }

        return try JSONDecoder().decode(SignInResponse.self, from: data)
    }

    // MARK: - Get Current User

    struct User: Codable {
        let id: String
        let primary_email: String?
        let display_name: String?
    }

    func getCurrentUser(accessToken: String) async throws -> User {
        let url = URL(string: "\(baseURL)/users/me")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        commonHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue(accessToken, forHTTPHeaderField: "x-stack-access-token")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AuthError.unauthorized
        }

        return try JSONDecoder().decode(User.self, from: data)
    }

    // MARK: - Refresh Token

    struct RefreshResponse: Codable {
        let access_token: String
    }

    func refreshAccessToken(refreshToken: String) async throws -> String {
        let url = URL(string: "\(baseURL)/auth/sessions/current/refresh")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        commonHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue(refreshToken, forHTTPHeaderField: "x-stack-refresh-token")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AuthError.unauthorized
        }

        let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)
        return decoded.access_token
    }

    // MARK: - Sign Out

    func signOut(refreshToken: String) async throws {
        let url = URL(string: "\(baseURL)/auth/sessions/current")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        commonHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue(refreshToken, forHTTPHeaderField: "x-stack-refresh-token")

        let (_, _) = try await URLSession.shared.data(for: request)
        // Ignore response - sign out is best-effort
    }
}

enum AuthError: Error, LocalizedError {
    case networkError
    case serverError(Int, String)
    case invalidCode
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .networkError:
            return "Network error. Please check your connection."
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        case .invalidCode:
            return "Invalid code. Please try again."
        case .unauthorized:
            return "Session expired. Please sign in again."
        }
    }
}
