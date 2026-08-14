import CmuxAuthRuntime
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct CmuxSocketEventMapperTests {
    @Test
    func paneResizeEventDistinguishesAppliedFromRemoteRequested() {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }
        let command = #"{"id":1,"method":"pane.resize","params":{"direction":"right","amount":10}}"#
        let localResponse = #"{"id":1,"ok":true,"result":{"pane_id":"local-pane"}}"#
        let remoteResponse = #"{"id":1,"ok":true,"result":{"pane_id":"remote-pane","remote":true}}"#

        CmuxSocketEventMapper.publish(command: command, response: localResponse)
        CmuxSocketEventMapper.publish(command: command, response: remoteResponse)

        let events = CmuxEventBus.shared.retainedSnapshot()
        #expect(events.compactMap { $0["name"] as? String } == [
            "pane.resized",
            "pane.resize_requested",
        ])
        #expect(events.compactMap { $0["pane_id"] as? String } == [
            "local-pane",
            "remote-pane",
        ])
    }

    @Test
    func coderouterHandoffResponseIsNotPublishedToEvents() {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }
        let command = #"{"id":1,"method":"coderouter.handoff","params":{}}"#
        let lease = "crh_" + String(repeating: "A", count: 43)
        let response = #"{"id":1,"ok":true,"result":{"teamId":"team_a","lease":"\#(lease)","expiresAt":"2099-01-01T00:00:00Z"}}"#

        CmuxSocketEventMapper.publish(command: command, response: response)

        #expect(CmuxEventBus.shared.retainedSnapshot().isEmpty)
        #expect(!CmuxSocketEventMapper.redactedNotificationParams(["body": lease]).values.contains { value in
            (value as? String) == lease
        })
    }

    @Test
    func coderouterHandoffDoesNotUsePermissiveSocketModes() {
        #expect(TerminalController.codeRouterHandoffRequiresCmuxOnly(for: .allowAll))
        #expect(TerminalController.codeRouterHandoffRequiresCmuxOnly(for: .automation))
        #expect(!TerminalController.codeRouterHandoffRequiresCmuxOnly(for: .password))
        #expect(!TerminalController.codeRouterHandoffRequiresCmuxOnly(for: .cmuxOnly))
        #expect(!TerminalController.codeRouterHandoffRequiresCmuxOnly(for: .off))
        #expect(TerminalController.isCodeRouterHandoffCommand(#"{"method":"coderouter.handoff","params":{}}"#))
        let oversized = #"{"method":"coderouter.handoff","params":{},"padding":""}"#
            .replacingOccurrences(of: #""padding":"""#, with: "\"padding\":\"\(String(repeating: "x", count: 5_000))\"")
        #expect(oversized.utf8.count > 4_096)
        #expect(TerminalController.isCodeRouterHandoffCommand(oversized))
    }
}

private actor CodeRouterHandoffTestAuth: CodeRouterHandoffAuthProviding {
    private var snapshot: AuthenticatedSessionSnapshot
    private var current = true
    private var teamID: String?

    init(teamID: String? = "team_a") {
        self.snapshot = AuthenticatedSessionSnapshot(
            generation: 1,
            accountID: "account_a",
            accessToken: "access-secret",
            refreshToken: "refresh-secret"
        )
        self.teamID = teamID
    }

    func authenticatedSessionSnapshot() async throws -> AuthenticatedSessionSnapshot {
        guard current else { throw AuthError.unauthorized }
        return snapshot
    }

    func isAuthenticatedSessionCurrent(_ snapshot: AuthenticatedSessionSnapshot) async -> Bool {
        current && snapshot == self.snapshot
    }

    func codeRouterHandoffResolvedTeamID() async -> String? { teamID }

    func signOut() { current = false }
    func changeTeam(to teamID: String?) { self.teamID = teamID }
    func switchAccount() {
        snapshot = AuthenticatedSessionSnapshot(
            generation: snapshot.generation + 1,
            accountID: "account_b",
            accessToken: "new-access-secret",
            refreshToken: "new-refresh-secret"
        )
    }
}

private actor CodeRouterHandoffRequestProbe {
    private(set) var request: URLRequest?
    private var continuation: CheckedContinuation<Void, Never>?

    func record(_ request: URLRequest) {
        self.request = request
        continuation?.resume()
        continuation = nil
    }

    func waitForRequest() async {
        if request != nil { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

private actor CodeRouterHandoffGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@Suite("CodeRouter native handoff client")
struct CodeRouterHandoffClientTests {
    private let baseURL = URL(string: "http://127.0.0.1:39123")!

    @Test
    func mintsLeaseWithNativeHeadersAndNoCookies() async throws {
        let auth = CodeRouterHandoffTestAuth()
        let probe = CodeRouterHandoffRequestProbe()
        let lease = "crh_" + String(repeating: "B", count: 43)
        let expiry = "2099-01-01T00:00:00Z"
        let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            await probe.record(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Cache-Control": "no-store"]
            )!
            let data = try JSONSerialization.data(withJSONObject: [
                "teamId": "team_a",
                "lease": lease,
                "expiresAt": expiry,
            ])
            return (data, response)
        }
        let client = CodeRouterHandoffClient(
            auth: auth,
            baseURL: baseURL,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
            requestHandler: handler
        )

        let result = try await client.mint()
        #expect(result == CodeRouterHandoffLease(teamID: "team_a", lease: lease, expiresAt: expiry))
        let request = await probe.request
        #expect(request?.url?.path == "/api/coderouter/handoff")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer access-secret")
        #expect(request?.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == "refresh-secret")
        #expect(request?.value(forHTTPHeaderField: "X-Cmux-Team-Id") == "team_a")
        #expect(request?.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request?.value(forHTTPHeaderField: "X-Cmux-Native") == nil)
        #expect(request?.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request?.httpShouldHandleCookies == false)
        #expect(String(data: request?.httpBody ?? Data(), encoding: .utf8) == "{}")
    }

    @Test
    func rejectsAccountOrTeamChangeBeforeReturningLease() async throws {
        let auth = CodeRouterHandoffTestAuth()
        let gate = CodeRouterHandoffGate()
        let probe = CodeRouterHandoffRequestProbe()
        let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            await probe.record(request)
            await gate.wait()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = try JSONSerialization.data(withJSONObject: [
                "teamId": "team_a",
                "lease": "crh_" + String(repeating: "C", count: 43),
                "expiresAt": "2099-01-01T00:00:00Z",
            ])
            return (data, response)
        }
        let client = CodeRouterHandoffClient(auth: auth, baseURL: baseURL, requestHandler: handler)
        let task = Task { try await client.mint() }
        await probe.waitForRequest()
        await auth.signOut()
        await auth.changeTeam(to: "team_b")
        await gate.release()

        do {
            _ = try await task.value
            Issue.record("handoff returned a lease after sign-out/team change")
        } catch let error as CodeRouterHandoffClientError {
            #expect(error == .sessionChanged)
        }
    }

    @Test
    func rejectsAccountChangeBeforeReturningLease() async throws {
        let auth = CodeRouterHandoffTestAuth()
        let gate = CodeRouterHandoffGate()
        let probe = CodeRouterHandoffRequestProbe()
        let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            await probe.record(request)
            await gate.wait()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = try JSONSerialization.data(withJSONObject: [
                "teamId": "team_a",
                "lease": "crh_" + String(repeating: "F", count: 43),
                "expiresAt": "2099-01-01T00:00:00Z",
            ])
            return (data, response)
        }
        let client = CodeRouterHandoffClient(auth: auth, baseURL: baseURL, requestHandler: handler)
        let task = Task { try await client.mint() }
        await probe.waitForRequest()
        await auth.switchAccount()
        await gate.release()

        do {
            _ = try await task.value
            Issue.record("handoff returned a lease after account change")
        } catch let error as CodeRouterHandoffClientError {
            #expect(error == .sessionChanged)
        }
    }

    @Test
    func rejectsExpiredAndReplayedResponsesWithoutEchoingBody() async throws {
        let auth = CodeRouterHandoffTestAuth()
        let secretLease = "crh_" + String(repeating: "D", count: 43)
        let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            let data = Data(#"{"error":"invalid_handoff_lease","lease":"\#(secretLease)"}"#.utf8)
            return (data, response)
        }
        let client = CodeRouterHandoffClient(auth: auth, baseURL: baseURL, requestHandler: handler)

        do {
            _ = try await client.mint()
            Issue.record("expected 401 handoff error")
        } catch let error as CodeRouterHandoffClientError {
            #expect(error == .httpStatus(401))
            #expect(!error.description.contains(secretLease))
        }
    }

    @Test
    func rejectsExpiredAndOversizedSuccessBodies() async throws {
        let auth = CodeRouterHandoffTestAuth()
        let expiredHandler: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = try JSONSerialization.data(withJSONObject: [
                "teamId": "team_a",
                "lease": "crh_" + String(repeating: "E", count: 43),
                "expiresAt": "2000-01-01T00:00:00Z",
            ])
            return (data, response)
        }
        let expiredClient = CodeRouterHandoffClient(
            auth: auth,
            baseURL: baseURL,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
            requestHandler: expiredHandler
        )
        do {
            _ = try await expiredClient.mint()
            Issue.record("expected expired lease failure")
        } catch let error as CodeRouterHandoffClientError {
            #expect(error == .expiredLease)
        }

        let oversizedHandler: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(repeating: 0x41, count: 16 * 1024 + 1), response)
        }
        let oversizedClient = CodeRouterHandoffClient(
            auth: auth,
            baseURL: baseURL,
            requestHandler: oversizedHandler
        )
        do {
            _ = try await oversizedClient.mint()
            Issue.record("expected oversized response failure")
        } catch let error as CodeRouterHandoffClientError {
            #expect(error == .invalidResponse)
        }
    }

    @Test
    func rejectsUntrustedHostAndInvalidLeaseSyntax() async throws {
        let auth = CodeRouterHandoffTestAuth()
        let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { _ in
            Issue.record("untrusted host must not receive a request")
            throw URLError(.badURL)
        }
        let client = CodeRouterHandoffClient(
            auth: auth,
            baseURL: URL(string: "https://evil.example")!,
            requestHandler: handler
        )
        do {
            _ = try await client.mint()
            Issue.record("expected invalid host failure")
        } catch let error as CodeRouterHandoffClientError {
            #expect(error == .invalidResponse)
        }
        #expect(!CodeRouterHandoffClient.isValidLeaseSyntax("crh_short"))
        #expect(!CodeRouterHandoffClient.isValidLeaseSyntax("crh_" + String(repeating: "!", count: 43)))
    }

    @Test
    func rejectsRedirectedMintResponse() async throws {
        let auth = CodeRouterHandoffTestAuth()
        let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            let redirected = HTTPURLResponse(
                url: URL(string: "https://evil.example/api/coderouter/handoff")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data("{}".utf8), redirected)
        }
        let client = CodeRouterHandoffClient(auth: auth, baseURL: baseURL, requestHandler: handler)
        do {
            _ = try await client.mint()
            Issue.record("expected redirected response failure")
        } catch let error as CodeRouterHandoffClientError {
            #expect(error == .redirectedResponse)
        }
    }

    @Test
    func rejectsTeamMismatchForExplicitTeamRequest() async throws {
        let auth = CodeRouterHandoffTestAuth()
        let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = try JSONSerialization.data(withJSONObject: [
                "teamId": "team_a",
                "lease": "crh_" + String(repeating: "G", count: 43),
                "expiresAt": "2099-01-01T00:00:00Z",
            ])
            return (data, response)
        }
        let client = CodeRouterHandoffClient(auth: auth, baseURL: baseURL, requestHandler: handler)
        do {
            _ = try await client.mint(teamID: "team_b")
            Issue.record("expected explicit team mismatch failure")
        } catch let error as CodeRouterHandoffClientError {
            #expect(error == .invalidResponse)
        }
    }
}
