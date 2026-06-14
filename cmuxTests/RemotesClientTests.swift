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
}
