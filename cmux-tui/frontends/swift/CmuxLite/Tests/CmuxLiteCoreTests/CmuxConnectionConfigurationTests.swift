@testable import CmuxLiteCore
import Foundation
import Testing

@Suite
struct CmuxConnectionConfigurationTests {
    private let environment = ["TMPDIR": "/private/tmp/example", "HOME": "/Users/tester"]

    @Test
    func sessionUsesServerCompatibleSocketPathWithoutAuthentication() throws {
        let configuration = try parse(["--session", "phone"])

        #expect(
            configuration.endpoint == .unixSocket(
                path: "/private/tmp/example/cmux-tui-501/phone.sock"
            )
        )
        #expect(configuration.token == nil)
    }

    @Test
    func exactlyOneDiscoveredSocketBecomesTheDefault() throws {
        let socket = "/private/tmp/example/cmux-tui-501/phone.sock"
        let configuration = try parse([], sockets: [socket, "/tmp/not-a-socket.txt"])

        #expect(configuration.endpoint == .unixSocket(path: socket))
    }

    @Test
    func ambiguousDefaultListsSocketsAndRequiresASelector() {
        let first = "/private/tmp/example/cmux-tui-501/main.sock"
        let second = "/private/tmp/example/cmux-tui-501/phone.sock"

        do {
            _ = try parse([], sockets: [second, first])
            Issue.record("Expected ambiguous socket discovery to fail")
        } catch let error as CmuxProtocolError {
            let message = error.description
            #expect(message.contains(first))
            #expect(message.contains(second))
            #expect(message.contains("--socket"))
            #expect(message.contains("--session"))
            #expect(message.contains("--url"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func webSocketUsesTokenFileFallback() throws {
        let configuration = try CmuxConnectionConfiguration.parse(
            arguments: ["--url", "ws://127.0.0.1:7682"],
            environment: environment,
            userID: 501,
            readFile: { path in
                #expect(path == "/Users/tester/.config/cmux-lite/token")
                return " secret\n"
            },
            listDirectory: { _ in [] }
        )

        #expect(
            configuration.endpoint == .webSocket(
                url: try #require(URL(string: "ws://127.0.0.1:7682"))
            )
        )
        #expect(configuration.token == "secret")
    }

    private func parse(
        _ arguments: [String],
        sockets: [String] = [],
        live: [String]? = nil
    ) throws -> CmuxConnectionConfiguration {
        try CmuxConnectionConfiguration.parse(
            arguments: arguments,
            environment: environment,
            userID: 501,
            readFile: { _ in throw TestError.unexpectedRead },
            listDirectory: { _ in sockets },
            isSocketLive: { path in (live ?? sockets).contains(path) }
        )
    }

    @Test
    func discoveryIgnoresStaleSocketsAndPicksTheSoleLiveOne() throws {
        let configuration = try parse(
            [],
            sockets: ["stale-a.sock", "phone.sock", "stale-b.sock"],
            live: ["phone.sock"]
        )
        #expect(configuration.endpoint == .unixSocket(path: "phone.sock"))
    }

    @Test
    func discoveryFailsWhenNoSocketIsLive() {
        #expect(throws: CmuxProtocolError.self) {
            _ = try parse([], sockets: ["stale-a.sock", "stale-b.sock"], live: [])
        }
    }

    @Test
    func discoveryFailsWhenMultipleSocketsAreLive() {
        #expect(throws: CmuxProtocolError.self) {
            _ = try parse([], sockets: ["a.sock", "b.sock"], live: ["a.sock", "b.sock"])
        }
    }

    private enum TestError: Error {
        case unexpectedRead
    }

    @Test
    func socketDirectoryPrefersXdgRuntimeDirOverTmpdir() {
        let dir = CmuxConnectionConfiguration.socketDirectory(
            environment: ["XDG_RUNTIME_DIR": "/run/user/501", "TMPDIR": "/var/tmp-x"],
            userID: 501
        )
        #expect(dir == "/run/user/501/cmux-tui-501")
        let empty = CmuxConnectionConfiguration.socketDirectory(
            environment: ["XDG_RUNTIME_DIR": "", "TMPDIR": "/var/tmp-x"],
            userID: 501
        )
        #expect(empty == "/var/tmp-x/cmux-tui-501")
    }
}
