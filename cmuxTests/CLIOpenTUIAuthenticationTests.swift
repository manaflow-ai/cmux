import CmuxSettings
import Foundation
import Testing

/// Exercises credential handoff at the shipped CLI's OpenTUI subprocess boundary.
struct CLIOpenTUIAuthenticationTests {
    @Test(arguments: [false, true])
    func successfulWarmupHandsOnlyRequiredPasswordToChild(requiresPassword: Bool) throws {
        let root = try makeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("control.sock").path
        let success = #"{"ok":true,"result":{"items":[]}}"#
        let responses = requiresPassword
            ? [#"{"ok":false,"error":{"code":"auth_required","message":"Authentication required — send auth <password> first"}}"#,
               "OK: Authenticated", success]
            : [success]
        let server = try UnixSocketResponder(path: socketPath, responses: responses)
        defer { server.stop() }

        let result = try runFeed(root: root, socketPath: socketPath)
        #expect(!result.timedOut, "\(result.diagnostics)")
        try #require(result.status == 0, "\(result.diagnostics)")
        let childPassword = try String(contentsOf: launchMarker(root), encoding: .utf8)
        #expect(childPassword == (requiresPassword ? "opentui-test-password" : "<unset>"))
        let requests = server.receivedRequests
        try #require(requests.count == (requiresPassword ? 3 : 1))
        #expect(requests[0].contains("feed.list"))
        if requiresPassword {
            #expect(requests[1] == "auth opentui-test-password")
            #expect(requests[2] == requests[0], "Replay must preserve the challenged request")
        }
    }

    @Test(arguments: ["connect", "timeout", "unclassified"])
    func failedWarmupDoesNotLaunchCredentiallessChild(failure: String) throws {
        let root = try makeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("control.sock").path
        // Delaying a response models the real warm-up deadline, not synchronization.
        let server = try failure == "connect" ? nil : UnixSocketResponder(
            path: socketPath,
            response: #"{"ok":false,"error":{"code":"unavailable","message":"try again"}}"#,
            responseDelay: failure == "timeout" ? 3 : 0
        )
        defer { server?.stop() }

        let result = try runFeed(root: root, socketPath: socketPath)
        #expect(!result.timedOut, "\(result.diagnostics)")
        #expect(result.status != 0, "\(result.diagnostics)")
        #expect(!FileManager.default.fileExists(atPath: launchMarker(root).path))
        if let server {
            #expect(server.receivedRequests.count == 1)
            #expect(server.receivedRequests.first?.contains("feed.list") == true)
        }
    }

    @Test(arguments: [false, true])
    func failedFeedRequestPreservesKnownPasswordForChild(explicit: Bool) throws {
        let root = try makeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("control.sock").path
        let failure = #"{"ok":false,"error":{"code":"unavailable","message":"try again"}}"#
        let responses = explicit ? ["OK: Authenticated", failure] : [
            #"{"ok":false,"error":{"code":"auth_required","message":"Authentication required — send auth <password> first"}}"#,
            "OK: Authenticated", failure
        ]
        let server = try UnixSocketResponder(path: socketPath, responses: responses)
        defer { server.stop() }

        let result = try runFeed(root: root, socketPath: socketPath, explicitPassword: explicit)
        #expect(!result.timedOut, "\(result.diagnostics)")
        try #require(result.status == 0, "\(result.diagnostics)")
        #expect(try String(contentsOf: launchMarker(root), encoding: .utf8) == "opentui-test-password")
        let requests = server.receivedRequests
        #expect(requests.count == (explicit ? 2 : 3))
        #expect(requests.filter { $0 == "auth opentui-test-password" }.count == 1)
    }

    @Test
    func automaticModeFallsBackWithoutLaunchingChildAfterWarmupFailure() throws {
        let root = try makeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("control.sock").path
        let server = try UnixSocketResponder(
            path: socketPath,
            response: #"{"ok":false,"error":{"code":"unavailable","message":"try again"}}"#
        )
        defer { server.stop() }

        let result = try runFeed(root: root, socketPath: socketPath, automatic: true)
        #expect(!result.timedOut, "\(result.diagnostics)")
        #expect(result.status != 0, "\(result.diagnostics)")
        #expect((result.stdout + result.stderr).contains("falling back to legacy TUI"))
        #expect(!FileManager.default.fileExists(atPath: launchMarker(root).path))
        #expect(server.receivedRequests.count == 2, "Both warm-up and legacy must contact the server")
    }

    private func makeHome() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/cmx-tui-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let stateDirectory = CmuxStateDirectory.url(homeDirectory: root)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let passwordURL = stateDirectory.appendingPathComponent(SocketControlPasswordStore.fileName)
        try Data("opentui-test-password".utf8).write(to: passwordURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordURL.path)
        let bunURL = root.appendingPathComponent("bun")
        try """
        #!/bin/sh
        if [ "$1" = install ]; then exit 0; fi
        printf '%s' "${CMUX_SOCKET_PASSWORD-<unset>}" > "$CMUX_TEST_OPEN_TUI_LAUNCH_PATH"
        """.write(to: bunURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bunURL.path)
        return root
    }

    private func launchMarker(_ root: URL) -> URL {
        root.appendingPathComponent("child-password")
    }

    private func runFeed(
        root: URL, socketPath: String, automatic: Bool = false, explicitPassword: Bool = false
    ) throws -> CMUXCLIErrorOutputRegressionTests.ProcessRunResult {
        let support = CMUXCLIErrorOutputRegressionTests()
        let cliPath = try support.bundledCLIPath()
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CMUX") }
        environment["HOME"] = root.path
        environment["CFFIXED_USER_HOME"] = root.path
        environment["TERM"] = "xterm-256color"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_FEED_TUI_BUN_PATH"] = root.appendingPathComponent("bun").path
        environment["CMUX_TEST_OPEN_TUI_LAUNCH_PATH"] = launchMarker(root).path
        if explicitPassword { environment["CMUX_SOCKET_PASSWORD"] = "opentui-test-password" }
        let transcript = root.appendingPathComponent("terminal-output")
        let result = support.runProcess(
            executablePath: "/usr/bin/script",
            arguments: ["-q", transcript.path, cliPath, "--socket", socketPath, "feed", "tui"]
                + (automatic ? [] : ["--opentui"]),
            environment: environment,
            timeout: 10
        )
        return .init(
            status: result.status,
            stdout: (try? String(contentsOf: transcript, encoding: .utf8)) ?? "",
            stderr: result.stderr,
            timedOut: result.timedOut,
            terminationReason: result.terminationReason
        )
    }
}
