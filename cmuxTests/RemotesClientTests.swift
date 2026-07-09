import Foundation
import Testing
import CMUXMobileCore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests the pure request-shaping for `cmux remotes`: host:port parsing, the
/// loopback refusal (a phone could never dial a localhost remote), deterministic
/// name → deviceId idempotency, and the stored-route display parsing that
/// tolerates both wire shapes. These run without any network or running app.
@Suite struct RemotesClientTests {

    // MARK: - Route parsing

    @Test func parsesPlainHostPort() throws {
        let spec = try RemoteRouteSpec.parse("100.64.1.2:51001")
        #expect(spec.host == "100.64.1.2")
        #expect(spec.port == 51001)
    }

    @Test func parsesTailscaleNameHostPort() throws {
        let spec = try RemoteRouteSpec.parse("my-mac.tailnet.ts.net:51001")
        #expect(spec.host == "my-mac.tailnet.ts.net")
        #expect(spec.port == 51001)
    }

    @Test func parsesBracketedIPv6() throws {
        let spec = try RemoteRouteSpec.parse("[fd7a:115c:a1e0::1]:51001")
        #expect(spec.host == "fd7a:115c:a1e0::1")
        #expect(spec.port == 51001)
    }

    @Test func trimsSurroundingWhitespace() throws {
        let spec = try RemoteRouteSpec.parse("  100.64.1.2:51001  ")
        #expect(spec.host == "100.64.1.2")
        #expect(spec.port == 51001)
    }

    @Test func rejectsMissingPort() {
        #expect(throws: RemotesClientError.self) {
            _ = try RemoteRouteSpec.parse("100.64.1.2")
        }
    }

    @Test func rejectsOutOfRangePort() {
        #expect(throws: RemotesClientError.self) {
            _ = try RemoteRouteSpec.parse("100.64.1.2:70000")
        }
        #expect(throws: RemotesClientError.self) {
            _ = try RemoteRouteSpec.parse("100.64.1.2:0")
        }
    }

    @Test func rejectsEmptyHost() {
        #expect(throws: RemotesClientError.self) {
            _ = try RemoteRouteSpec.parse(":51001")
        }
    }

    @Test func rejectsBareUnbracketedIPv6() {
        // Ambiguous: which colon is the port separator? Require brackets.
        #expect(throws: RemotesClientError.self) {
            _ = try RemoteRouteSpec.parse("fd7a:115c:a1e0::1:51001")
        }
    }

    // MARK: - Loopback refusal

    @Test(arguments: [
        "localhost:51001",
        "localhost.:51001",
        "sub.localhost:51001",
        "127.0.0.1:51001",
        "127.1:51001",
        "0.0.0.0:51001",
        "[::1]:51001",
        "[::]:51001",
        "[::ffff:127.0.0.1]:51001",
    ])
    func rejectsLoopbackRoutes(_ token: String) {
        #expect(throws: RemotesClientError.self) {
            _ = try RemoteRouteSpec.parse(token)
        }
    }

    @Test func loopbackErrorNamesTheHost() {
        do {
            _ = try RemoteRouteSpec.parse("127.0.0.1:51001")
            Issue.record("expected loopback rejection")
        } catch let error as RemotesClientError {
            #expect(error == .loopbackRoute(host: "127.0.0.1"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test(arguments: [
        "100.64.1.2:51001",
        "192.168.1.50:51001",
        "10.0.0.5:51001",
        "my-mac.tailnet.ts.net:51001",
        "[fd7a:115c:a1e0::1]:51001",
    ])
    func acceptsNonLoopbackRoutes(_ token: String) throws {
        // Must not throw.
        _ = try RemoteRouteSpec.parse(token)
    }

    // MARK: - Attach route wire shape

    @Test func buildsTailscaleHostPortAttachRoute() throws {
        let spec = try RemoteRouteSpec.parse("100.64.1.2:51001")
        let route = try spec.attachRoute(id: "manual-0", priority: 0)
        #expect(route.kind == .tailscale)
        #expect(route.endpoint == .hostPort(host: "100.64.1.2", port: 51001))
    }

    // MARK: - Attachability (the iOS auth policy gate)

    @Test(arguments: [
        "100.64.1.2:51001",     // CGNAT lower bound
        "100.127.255.255:51001", // CGNAT upper bound
        "100.100.50.7:51001",
        "my-mac.tailnet.ts.net:51001",
        "MY-MAC.TS.NET:51001",  // case-insensitive suffix
    ])
    func acceptsTailscaleAttachableHosts(_ token: String) throws {
        let spec = try RemoteRouteSpec.parse(token)
        #expect(spec.isTailscaleAttachable)
    }

    @Test(arguments: [
        "192.168.1.50:51001",   // private LAN
        "10.0.0.5:51001",       // private LAN
        "172.16.0.9:51001",
        "100.63.0.1:51001",     // just below CGNAT
        "100.128.0.1:51001",    // just above CGNAT
        "8.8.8.8:51001",        // public, not Tailscale
        "my-mac.local:51001",   // bonjour
        "example.com:51001",    // bare hostname
        "[fd7a:115c:a1e0::1]:51001", // Tailscale IPv6 ULA (no IPv6 auth path)
        "bad host.ts.net:51001", // malformed .ts.net (space) — not a valid host
        "mac_underscore.ts.net:51001", // invalid label char
        "-leading.ts.net:51001", // leading hyphen label
        "0100.64.1.2:51001",    // leading-zero octet (octal under inet_aton)
        "100.064.1.2:51001",    // leading-zero octet
    ])
    func rejectsNonTailscaleHostsAsNotAttachable(_ token: String) throws {
        let spec = try RemoteRouteSpec.parse(token)
        #expect(!spec.isTailscaleAttachable)
    }

    // MARK: - Deterministic device id (idempotency on name)

    @Test func deviceIdIsStableForSameName() {
        let a = RemotesClient.deviceId(forName: "my-studio")
        let b = RemotesClient.deviceId(forName: "my-studio")
        #expect(a == b)
    }

    @Test func deviceIdIsCaseAndWhitespaceInsensitive() {
        let a = RemotesClient.deviceId(forName: "My-Studio")
        let b = RemotesClient.deviceId(forName: "  my-studio ")
        #expect(a == b)
    }

    @Test func deviceIdDiffersByName() {
        let a = RemotesClient.deviceId(forName: "studio-a")
        let b = RemotesClient.deviceId(forName: "studio-b")
        #expect(a != b)
    }

    @Test func deviceIdIsStableForSameOwnerAndName() {
        let a = RemotesClient.deviceId(forName: "studio", ownerID: "user-1")
        let b = RemotesClient.deviceId(forName: "studio", ownerID: "user-1")
        #expect(a == b)
    }

    @Test func deviceIdDiffersByOwnerForSameName() {
        // Two team members adding the same name get distinct ids, so the second
        // does not collide with the first's row (`device_not_owned`).
        let a = RemotesClient.deviceId(forName: "studio", ownerID: "user-1")
        let b = RemotesClient.deviceId(forName: "studio", ownerID: "user-2")
        #expect(a != b)
    }

    @Test func ownerSaltDoesNotAliasByConcatenation() {
        // Length-prefixing prevents (owner "ab", name "c") aliasing
        // (owner "a", name "bc").
        let a = RemotesClient.deviceId(forName: "c", ownerID: "ab")
        let b = RemotesClient.deviceId(forName: "bc", ownerID: "a")
        #expect(a != b)
    }

    @Test func deviceIdIsAValidLowercaseUUID() {
        let id = RemotesClient.deviceId(forName: "my-studio")
        #expect(UUID(uuidString: id) != nil)
        #expect(id == id.lowercased())
        // RFC 4122 version-5 nibble.
        let versionNibble = Array(id.replacingOccurrences(of: "-", with: ""))[12]
        #expect(versionNibble == "5")
    }

    @Test func isUUIDRecognizesUUIDsAndRejectsNames() {
        #expect(RemotesClient.isUUID("11111111-1111-4111-8111-111111111111"))
        #expect(!RemotesClient.isUUID("my-studio"))
        #expect(!RemotesClient.isUUID(""))
    }

    // MARK: - Display route parsing (tolerates both stored shapes)

    @Test func parsesDisplayRoutesWithTypeField() {
        let raw: [[String: Any]] = [
            ["endpoint": ["type": "host_port", "host": "100.64.1.2", "port": 51001]],
        ]
        let routes = RemotesClient.parseDisplayRoutes(raw)
        #expect(routes.count == 1)
        #expect(routes[0].host == "100.64.1.2")
        #expect(routes[0].port == 51001)
    }

    @Test func parsesDisplayRoutesWithoutTypeField() {
        // Older stored rows lack the `type` key.
        let raw: [[String: Any]] = [
            ["endpoint": ["host": "100.9.9.9", "port": 51999]],
        ]
        let routes = RemotesClient.parseDisplayRoutes(raw)
        #expect(routes.count == 1)
        #expect(routes[0].host == "100.9.9.9")
        #expect(routes[0].port == 51999)
    }

    @Test func dropsRoutesMissingHostOrPort() {
        let raw: [[String: Any]] = [
            ["endpoint": ["host": "100.1.1.1", "port": 1]],
            ["endpoint": ["port": 2]],
            ["endpoint": ["host": "100.2.2.2"]],
            ["kind": "peer"],
        ]
        let routes = RemotesClient.parseDisplayRoutes(raw)
        #expect(routes.count == 1)
        #expect(routes[0].host == "100.1.1.1")
    }

    // Note: `CMUXCLI.sanitizeForTerminal` (used by `remotes list`) lives in the
    // CLI executable target, which `cmuxTests` does not link, so it cannot be
    // unit-tested here (referencing `CMUXCLI` breaks the test-target compile).
    // Its behavior is exercised via the tagged-build `remotes list` dogfood path.
}

@Suite struct AIAccountCredentialSourcesTests {
    private let sources = AIAccountCredentialSources(environment: [:])

    @Test func claudeCredentialsMapToUploadPayload() throws {
        let data = Data("""
        {
          "claudeAiOauth": {
            "accessToken": "claude-access-secret",
            "refreshToken": "claude-refresh-secret",
            "expiresAt": 1893456000,
            "subscriptionType": "pro",
            "rateLimitTier": "tier-1"
          }
        }
        """.utf8)

        let payload = try sources.claudeUploadPayload(credentialsData: data, label: " Work ")
        let body = payload.jsonBody
        #expect(body["provider"] as? String == "claude")
        #expect(body["label"] as? String == "Work")
        let oauth = try #require(body["claudeAiOauth"] as? [String: Any])
        #expect(oauth["accessToken"] as? String == "claude-access-secret")
        #expect(oauth["refreshToken"] as? String == "claude-refresh-secret")
        #expect(oauth["expiresAt"] as? Int == 1_893_456_000)
        #expect(oauth["subscriptionType"] as? String == "pro")
        #expect(oauth["rateLimitTier"] as? String == "tier-1")
        assertNoSecrets(payload.debugDescription, secrets: ["claude-access-secret", "claude-refresh-secret"])
    }

    @Test func claudeCredentialsRejectMissingRefreshToken() {
        let data = Data("""
        {
          "claudeAiOauth": {
            "accessToken": "claude-access-secret",
            "expiresAt": 1893456000
          }
        }
        """.utf8)

        #expect(throws: AIAccountCredentialSourceError.self) {
            _ = try sources.claudeUploadPayload(credentialsData: data, label: nil)
        }
        do {
            _ = try sources.claudeUploadPayload(credentialsData: data, label: nil)
            Issue.record("expected missing refreshToken")
        } catch {
            assertNoSecrets(String(describing: error), secrets: ["claude-access-secret"])
        }
    }

    @Test func claudeCredentialsRejectJunkJSON() {
        #expect(throws: AIAccountCredentialSourceError.self) {
            _ = try sources.claudeUploadPayload(credentialsData: Data("{not json".utf8), label: nil)
        }
    }

    @Test func codexAuthMapsSnakeCaseTokensToCamelCasePayload() throws {
        let data = Data("""
        {
          "tokens": {
            "access_token": "codex-access-secret",
            "refresh_token": "codex-refresh-secret",
            "id_token": "codex-id-secret",
            "account_id": "acct_123"
          }
        }
        """.utf8)

        let payload = try sources.codexUploadPayload(authData: data, label: nil)
        let body = payload.jsonBody
        #expect(body["provider"] as? String == "codex")
        let tokens = try #require(body["tokens"] as? [String: Any])
        #expect(tokens["accessToken"] as? String == "codex-access-secret")
        #expect(tokens["refreshToken"] as? String == "codex-refresh-secret")
        #expect(tokens["idToken"] as? String == "codex-id-secret")
        #expect(tokens["accountID"] as? String == "acct_123")
        #expect(tokens["access_token"] == nil)
        #expect(tokens["account_id"] == nil)
        assertNoSecrets(payload.debugDescription, secrets: ["codex-access-secret", "codex-refresh-secret", "codex-id-secret"])
    }

    @Test func codexAuthWithoutTokensButWithOpenAIKeySuggestsOpenAIKeyUpload() {
        let data = Data("""
        {
          "OPENAI_API_KEY": "sk-openai-secret"
        }
        """.utf8)

        do {
            _ = try sources.codexUploadPayload(authData: data, label: nil)
            Issue.record("expected missing tokens")
        } catch let error as AIAccountCredentialSourceError {
            let message = error.description
            #expect(message.contains("openai-key"))
            assertNoSecrets(message, secrets: ["sk-openai-secret"])
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func apiKeyExplicitFlagTakesPrecedenceOverEnvironment() throws {
        let sources = AIAccountCredentialSources(environment: ["ANTHROPIC_API_KEY": "sk-ant-env-secret"])
        let payload = try sources.apiKeyUploadPayload(
            provider: .anthropicKey,
            label: "anthropic",
            explicitAPIKey: "sk-ant-flag-secret"
        )
        let body = payload.jsonBody
        #expect(body["provider"] as? String == "anthropic-apikey")
        #expect(body["label"] as? String == "anthropic")
        #expect(body["apiKey"] as? String == "sk-ant-flag-secret")
        assertNoSecrets(payload.debugDescription, secrets: ["sk-ant-flag-secret", "sk-ant-env-secret"])
    }

    @Test func apiKeyFallsBackToEnvironmentWhenFlagMissing() throws {
        let sources = AIAccountCredentialSources(environment: ["OPENAI_API_KEY": "sk-openai-env-secret"])
        let payload = try sources.apiKeyUploadPayload(provider: .openAIKey, label: nil, explicitAPIKey: nil)
        let body = payload.jsonBody
        #expect(body["provider"] as? String == "openai-apikey")
        #expect(body["apiKey"] as? String == "sk-openai-env-secret")
    }

    @Test func apiKeyReportsGuidanceWhenMissing() {
        do {
            _ = try sources.apiKeyUploadPayload(provider: .openAIKey, label: nil, explicitAPIKey: nil)
            Issue.record("expected missing API key")
        } catch let error as AIAccountCredentialSourceError {
            #expect(error.description.contains("--key <value>"))
            #expect(error.description.contains("OPENAI_API_KEY"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func httpErrorFormattingRedactsServerEchoes() {
        let message = AIAccountsClient.formatHTTPError(
            status: 400,
            body: #"{"error":"bad api key sk-ant-secret12345 refresh_token codex-refresh-secret"}"#
        )
        assertNoSecrets(message, secrets: ["sk-ant-secret12345", "codex-refresh-secret"])
        #expect(message.contains("<redacted>"))
    }

    private func assertNoSecrets(_ value: String, secrets: [String]) {
        for secret in secrets {
            #expect(!value.contains(secret))
        }
    }
}
