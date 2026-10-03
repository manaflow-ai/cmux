import CMUXMobileCore
public import CmuxFeedPushCore
public import Foundation

/// The install credential the API Worker requires (identity spec D5:
/// install keypair, challenge, short-lived token). The iPhone app has no
/// install principal yet, so the default provider throws and every op is
/// refused locally until identity lands.
public protocol InstallTokenProviding: Sendable {
    func installToken() async throws -> String
}

public enum CloudOpsError: Error, Hashable, Sendable {
    /// No install principal on this device yet.
    case installTokenUnavailable
    /// HTTP-level refusal (auth, redirect, server error).
    case httpStatus(Int)
    /// The owner refused the op (`ok: false`).
    case rejected(code: String, retryable: Bool)
    case transport
    /// No valid API Worker origin is configured: nothing is sent.
    case notConfigured
}

/// Until the install principal exists: refuse, so nothing is sent unauthenticated.
public struct UnavailableInstallToken: InstallTokenProviding {
    public init() {}
    public func installToken() async throws -> String { throw CloudOpsError.installTokenUnavailable }
}

/// Sends typed ops to the API Worker (`POST /v1/ops`). Redirects are
/// refused, so the bearer never reaches another origin.
public protocol CloudOpsSending: Sendable {
    func send(_ op: CloudOp) async throws
}

public struct CloudOpsClient: CloudOpsSending {
    public let baseURL: URL
    public let tokens: any InstallTokenProviding
    private let session = CmxCredentialedHTTPSession()

    public init(baseURL: URL, tokens: any InstallTokenProviding) {
        self.baseURL = baseURL
        self.tokens = tokens
    }

    public func send(_ op: CloudOp) async throws {
        let token = try await tokens.installToken()
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/ops"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try op.body()
        request.timeoutInterval = 15
        let body: Data
        let response: URLResponse
        do { (body, response) = try await session.data(for: request) } catch {
            throw CloudOpsError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw CloudOpsError.transport }
        guard (200..<300).contains(http.statusCode) else { throw CloudOpsError.httpStatus(http.statusCode) }
        // A domain refusal is HTTP 200 with ok: false.
        if case .rejected(let code, let retryable) = CloudOpReply(body: body) {
            throw CloudOpsError.rejected(code: code, retryable: retryable)
        }
    }
}

/// Used when no valid API Worker origin is configured (fail closed).
public struct DisabledCloudOps: CloudOpsSending {
    public init() {}
    public func send(_ op: CloudOp) async throws { throw CloudOpsError.notConfigured }
}
