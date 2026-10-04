import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import StackAuth

/// A project that does not require publishable client keys accepts requests
/// without the header, but rejects a revoked key with
/// `INVALID_PUBLISHABLE_CLIENT_KEY`. A client built with an empty key must
/// therefore omit the header and use Stack's public-client OAuth secret, so
/// the key set that once issued the key can be revoked without signing
/// installed apps out.
@Suite(.serialized)
struct PublishableKeyOptionalTests {
    @Test func emptyKeyOmitsHeaderOnAPIRequests() async throws {
        PublishableKeyURLProtocol.reset()
        let client = makeClient(publishableClientKey: "")

        _ = try await client.sendRequest(path: "/projects/current")

        let requests = PublishableKeyURLProtocol.recorded
        #expect(requests.count == 1)
        #expect(requests.first?.publishableHeader == nil)
    }

    @Test func emptyKeyRefreshUsesPublicClientSecretWithoutHeader() async throws {
        PublishableKeyURLProtocol.reset()
        let client = makeClient(publishableClientKey: "")
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: "old-access", refreshToken: "refresh")

        _ = try await client.sendRequest(
            path: "/users/me",
            authenticated: true,
            tokenStoreOverride: store
        )

        let refresh = try #require(PublishableKeyURLProtocol.recorded.first { $0.isRefresh })
        #expect(refresh.publishableHeader == nil)
        #expect(refresh.formFields["client_secret"] == "__stack_public_client__")
        #expect(refresh.formFields["client_id"] == "project")
    }

    @Test func configuredKeyIsStillSent() async throws {
        PublishableKeyURLProtocol.reset()
        let client = makeClient(publishableClientKey: "publishable")
        let store = MemoryTokenStore()
        await store.setTokens(accessToken: "old-access", refreshToken: "refresh")

        _ = try await client.sendRequest(
            path: "/users/me",
            authenticated: true,
            tokenStoreOverride: store
        )

        let requests = PublishableKeyURLProtocol.recorded
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.publishableHeader == "publishable" })
        let refresh = try #require(requests.first { $0.isRefresh })
        #expect(refresh.formFields["client_secret"] == "publishable")
    }

    private func makeClient(publishableClientKey: String) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PublishableKeyURLProtocol.self]
        return APIClient(
            baseUrl: "https://stack-auth.test",
            projectId: "project",
            publishableClientKey: publishableClientKey,
            tokenStore: NullTokenStore(),
            session: URLSession(configuration: configuration)
        )
    }
}

private struct RecordedStackRequest: Sendable {
    let isRefresh: Bool
    let publishableHeader: String?
    let formFields: [String: String]
}

private final class PublishableKeyURLProtocol: URLProtocol, @unchecked Sendable {
    private static let newAccessToken =
        "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjk5OTk5OTk5OTksInN1YiI6InRlc3QifQ.signature"
    private static let lock = NSLock()
    private nonisolated(unsafe) static var requests: [RecordedStackRequest] = []

    static var recorded: [RecordedStackRequest] {
        lock.withLock { requests }
    }

    static func reset() {
        lock.withLock { requests = [] }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let isRefresh = request.url?.path.hasSuffix("/auth/oauth/token") == true
        let record = RecordedStackRequest(
            isRefresh: isRefresh,
            publishableHeader: request.value(forHTTPHeaderField: "x-stack-publishable-client-key"),
            formFields: isRefresh ? Self.formFields(of: request) : [:]
        )
        Self.lock.withLock { Self.requests.append(record) }

        let accessToken = request.value(forHTTPHeaderField: "x-stack-access-token")
        let authenticated = request.url?.path.hasSuffix("/users/me") == true
        let statusCode = isRefresh || !authenticated || accessToken == Self.newAccessToken ? 200 : 401
        let headers = statusCode == 200
            ? ["content-type": "application/json"]
            : ["x-stack-actual-status": "401", "x-stack-known-error": "invalid_access_token"]
        let body = isRefresh
            ? Data(#"{"access_token":"\#(Self.newAccessToken)"}"#.utf8)
            : Data(#"{"id":"project"}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession moves a request body into `httpBodyStream` before a
    /// protocol sees it, so read whichever one carries the form.
    private static func formFields(of request: URLRequest) -> [String: String] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: data, as: UTF8.self)
        var fields: [String: String] = [:]
        for item in components.queryItems ?? [] {
            fields[item.name] = item.value ?? ""
        }
        return fields
    }
}
