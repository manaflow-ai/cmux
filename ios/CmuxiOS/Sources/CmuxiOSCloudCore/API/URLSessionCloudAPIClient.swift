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

    public func attachmentIntent(params: [String: JSONValue]) async throws -> JSONValue {
        try await attachmentValuePost("v1/home/attachments/intent", params: params)
    }

    public func commitAttachment(conversation: String, slot: String) async throws -> JSONValue {
        try await attachmentValuePost("v1/home/attachments/commit", params: [
            "conversation": .string(conversation),
            "slot": .string(slot),
        ])
    }

    public func attachmentURL(params: [String: JSONValue]) async throws -> URL {
        let value = try await attachmentValuePost("v1/home/attachments/url", params: params)
        guard let string = value["url"]?.stringValue, let url = URL(string: string) else {
            throw CloudAPIError.transport
        }
        return url
    }

    public func uploadAttachmentBytes(file: URL, to uploadURL: URL, headers: [String: String] = [:],
                                      progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> JSONValue {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        progress(0)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, fromFile: file)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudAPIError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw CloudAPIError.transport }
        let body = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        guard (200..<300).contains(http.statusCode) else {
            throw CloudAPIError.refused(code: Self.code(in: body) ?? "http.\(http.statusCode)")
        }
        progress(1)
        return body["value"] ?? body
    }

    public func downloadAttachment(from url: URL, to destination: URL,
                                   progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        progress(0)
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await session.download(from: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudAPIError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw CloudAPIError.transport }
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? Data(contentsOf: temporary)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .null
            throw CloudAPIError.refused(code: Self.code(in: body) ?? "http.\(http.statusCode)")
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: temporary, to: destination)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudAPIError.transport
        }
        progress(1)
    }

    private func post(_ path: String, _ body: [String: JSONValue], as principal: CloudPrincipal) async throws -> (Int, JSONValue) {
        let first = try await attempt(path, body, as: principal)
        guard first.0 == 401 else { return first }
        await credentials.invalidate(principal)
        return try await attempt(path, body, as: principal)
    }

    /// Home attachment routes return the standard `{ok, value}` envelope but
    /// are not cloud operation names, so they share the authenticated POST
    /// transport while preserving the route-specific error code.
    private func attachmentValuePost(_ path: String, params: [String: JSONValue]) async throws -> JSONValue {
        let (status, body) = try await post(path, params, as: .session)
        guard (200..<300).contains(status) else {
            throw CloudAPIError.refused(code: Self.code(in: body) ?? "http.\(status)")
        }
        guard case .bool(true)? = body["ok"], let value = body["value"] else {
            throw CloudAPIError.transport
        }
        return value
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
