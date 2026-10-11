import Foundation
import Testing

@Suite
struct CLIRemotesArgumentValidationTests {
    @Test func listAcceptsOnlyEmptyOrJsonArguments() throws {
        try RemotesArgumentParser.validateList([])
        try RemotesArgumentParser.validateList(["--json"])

        try expectRemotesError(.unknownFlag("--typo")) {
            try RemotesArgumentParser.validateList(["--typo"])
        }
        try expectRemotesError(.unexpectedArgument("unexpected")) {
            try RemotesArgumentParser.validateList(["unexpected"])
        }
    }

    @Test func removeAcceptsOneTargetAndJsonOnly() throws {
        #expect(try RemotesArgumentParser.removeTarget(["studio"]) == "studio")
        #expect(try RemotesArgumentParser.removeTarget(["studio", "--json"]) == "studio")
        #expect(try RemotesArgumentParser.removeTarget(["--json", "studio"]) == "studio")
        #expect(try RemotesArgumentParser.removeTarget(["--json"]) == nil)
        #expect(try RemotesArgumentParser.removeTarget(["--", "my-studio"]) == "my-studio")
        #expect(try RemotesArgumentParser.removeTarget(["--", "-private"]) == "-private")

        try expectRemotesError(.unknownFlag("--typo")) {
            _ = try RemotesArgumentParser.removeTarget(["studio", "--typo"])
        }
        try expectRemotesError(.unexpectedArgument("unexpected")) {
            _ = try RemotesArgumentParser.removeTarget(["studio", "unexpected"])
        }
    }

    private func expectRemotesError(
        _ expected: RemotesArgumentError,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            Issue.record("Expected remotes argument validation to fail with \(expected)")
        } catch let error as RemotesArgumentError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Suite("VPN CLI argument validation", .serialized)
struct CLIVPNArgumentValidationTests {
    @Test func rejectsTrailingArgumentsBeforeTunnelRequest() throws {
        let cases = [
            ["vpn", "up", "--typo"],
            ["vpn", "on", "extra"],
            ["vpn", "down", "--typo"],
            ["vpn", "off", "extra"],
            ["vpn", "status", "--jsonn"],
            ["vpn", "revoke", "--typo"],
        ]

        for arguments in cases {
            let fixture = try CodexTeamsSocketFixture()
            defer { fixture.stop() }

            let result = CLIHookProcessRunner.run(
                executablePath: try BundledCLITestSupport.bundledCLIPath(),
                arguments: arguments,
                environment: [
                    "CMUX_SOCKET_PATH": fixture.path,
                    "CMUX_SOCKET_PASSWORD": "",
                    "CMUX_CLI_SENTRY_DISABLED": "1",
                    "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                ],
                timeout: 10
            )

            #expect(!result.timedOut)
            #expect(result.status == 1, Comment(rawValue: result.stderr))
            #expect(
                result.stderr.contains("Error: Usage: cmux vpn <up|down|status|revoke>"),
                Comment(rawValue: result.stderr)
            )
            let tunnelMethods = fixture.requestsSnapshot().compactMap { request in
                (request["method"] as? String).flatMap { method in
                    method.hasPrefix("vm.tunnel_") ? method : nil
                }
            }
            #expect(
                tunnelMethods.isEmpty,
                "Invalid VPN arguments must be rejected before contacting the tunnel service"
            )
        }
    }
}
