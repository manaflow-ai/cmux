public import CmuxMobileWire
public import Foundation

/// `CloudAPIClient` over URLSession. A 401 drops the token and retries once
/// with a fresh one (the same idempotency key). Redirects are refused, so
/// the bearer never reaches another origin.
public struct URLSessionCloudAPIClient: CloudAPIClient {
    private let baseURL: URL
    private let credentials: any CloudCredentials
    private let clientVersion: String?
    private let session: URLSession

    public init(baseURL: URL, credentials: any CloudCredentials, clientVersion: String? = nil) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.clientVersion = clientVersion
        session = URLSession(configuration: .ephemeral, delegate: CloudRedirectRefusal(), delegateQueue: nil)
    }

    public func read(_ op: String, params: [String: JSONValue]) async throws -> JSONValue {
        let (status, body) = try await post("v1/read", ["op": .string(op), "params": .object(params)], as: .install)
        guard (200..<300).contains(status) else { throw CloudAPIError.refused(code: Self.code(in: body) ?? "http.\(status)") }
        guard let value = body["value"] else { throw CloudAPIError.transport }
        return value
    }

    public func mutate(_ op: String, params: [String: JSONValue], key: String, as principal: CloudPrincipal) async throws -> CloudOpReply {
        let request = Self.mutationBody(op: op, params: params, key: key)
        let (status, body) = try await post("v1/ops", request, as: principal)
        guard (200..<300).contains(status) else {
            return .rejected(code: Self.code(in: body) ?? "http.\(status)", retryable: status == 503)
        }
        guard case .bool(let ok)? = body["ok"] else { throw CloudAPIError.transport }
        if ok {
            return .committed(value: body["value"] ?? .null, revision: CloudWireDecoder.revision(body["revision"]?.stringValue))
        }
        var retryable = false
        if case .bool(let flag)? = body["error"]?["retryable"] { retryable = flag }
        return .rejected(code: Self.code(in: body) ?? "unknown", retryable: retryable)
    }

    private func post(_ path: String, _ body: [String: JSONValue], as principal: CloudPrincipal) async throws -> (Int, JSONValue) {
        let first = try await attempt(path, body, as: principal)
        guard first.0 == 401 else { return first }
        await credentials.invalidate(principal)
        return try await attempt(path, body, as: principal)
    }

    private func attempt(_ path: String, _ body: [String: JSONValue], as principal: CloudPrincipal) async throws -> (Int, JSONValue) {
        let token: String
        do { token = try await credentials.token(for: principal) } catch { throw CloudAPIError.unauthenticated }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 40
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let clientVersion { request.setValue(clientVersion, forHTTPHeaderField: "x-cmux-client-version") }
        request.httpBody = try JSONValue.object(body).canonicalData()
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw CloudAPIError.transport }
        guard let http = response as? HTTPURLResponse else { throw CloudAPIError.transport }
        let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        return (http.statusCode, json)
    }

    /// `{error: {code}}` (ops) or a tagged error's top-level `code`.
    static func code(in body: JSONValue) -> String? {
        body["error"]?["code"]?.stringValue ?? body["code"]?.stringValue
    }

    /// Builds an ops body while preserving the protocol's non-idempotent
    /// `cloud.machine.link_token` shape (no `idempotency_key` member).
    public static func mutationBody(op: String, params: [String: JSONValue], key: String) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["op": .string(op), "params": .object(params),
                                         "origin": .string("user")]
        if !key.isEmpty { body["idempotency_key"] = .string(key) }
        return body
    }
}
