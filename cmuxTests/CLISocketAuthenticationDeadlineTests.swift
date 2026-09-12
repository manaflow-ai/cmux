import CmuxSettings
import Foundation
import Testing

/// Exercises authentication framing through the shipped CLI and real Unix sockets.
struct CLISocketAuthenticationDeadlineTests {
    @Test(arguments: [false, true])
    func savedPasswordChallengeFitsResizeDeadline(useV2: Bool) throws {
        let support = CMUXCLIErrorOutputRegressionTests()
        let cliPath = try support.bundledCLIPath()
        let root = try makeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDirectory = CmuxStateDirectory.url(homeDirectory: root)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let passwordURL = stateDirectory.appendingPathComponent(SocketControlPasswordStore.fileName)
        try Data("deadline-test-password".utf8).write(to: passwordURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordURL.path)

        let socketPath = root.appendingPathComponent("control.sock").path
        let challenge = useV2
            ? #"{"ok":false,"error":{"code":"auth_required","message":"send auth <password> first"}}"#
            : "ERROR: Authentication required — send auth <password> first"
        let response = useV2 ? #"{"ok":true,"result":{"resized":true}}"# : "PONG"
        let server = try UnixSocketResponder(
            path: socketPath,
            responses: Array(repeating: [challenge, "OK: Authenticated", response], count: 2).flatMap { $0 }
        )
        defer { server.stop() }
        let params = #"{"workspace_id":"11111111-1111-1111-1111-111111111111","cols":120,"rows":40}"#
        let command = useV2 ? ["rpc", "workspace.remote.pty_resize", params] : ["ping"]

        // Each invocation creates a fresh credential-free client, as the resize
        // monitor does. The server keeps the connection open after its replies.
        for invocation in 0..<2 {
            let result = support.runProcess(
                executablePath: cliPath,
                arguments: ["--socket", socketPath] + command,
                environment: environment(home: root, responseTimeout: "0.05"),
                timeout: 5
            )
            #expect(!result.timedOut, "\(result.diagnostics)")
            try #require(result.status == 0, "\(result.diagnostics)")
            if useV2 {
                let object = try #require(
                    JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Bool]
                )
                #expect(object["resized"] == true)
            } else {
                #expect(result.stdout == "PONG\n")
            }
            let requests = server.receivedRequests
            try #require(requests.count == (invocation + 1) * 3)
            let offset = invocation * 3
            #expect(requests[offset + 1] == "auth deadline-test-password")
            #expect(requests[offset] == requests[offset + 2], "Replay must preserve the original request")
            if useV2 {
                let request = try #require(
                    JSONSerialization.jsonObject(with: Data(requests[offset].utf8)) as? [String: Any]
                )
                #expect(request["method"] as? String == "workspace.remote.pty_resize")
            } else {
                #expect(requests[offset] == "ping")
            }
        }
    }

    @Test
    func streamV2ReauthenticatesWithResolvedPasswordAfterASecondChallenge() throws {
        let support = CMUXCLIErrorOutputRegressionTests()
        let cliPath = try support.bundledCLIPath()
        let root = try makeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDirectory = CmuxStateDirectory.url(homeDirectory: root)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let passwordURL = stateDirectory.appendingPathComponent(SocketControlPasswordStore.fileName)
        try Data("stream-test-password".utf8).write(to: passwordURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordURL.path)

        let socketPath = root.appendingPathComponent("control.sock").path
        let challenge = #"{"ok":false,"error":{"code":"auth_required","message":"send auth <password> first"}}"#
        let event = #"{"type":"event","seq":1,"name":"test.event","data":{}}"#
        let server = try UnixSocketResponder(
            path: socketPath,
            responses: [challenge, "OK: Authenticated", challenge, "OK: Authenticated", event]
        )
        defer { server.stop() }

        let result = support.runProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "events", "--limit", "1", "--no-ack", "--no-heartbeat"],
            environment: environment(home: root, responseTimeout: "1"),
            timeout: 5
        )
        #expect(!result.timedOut, "\(result.diagnostics)")
        try #require(result.status == 0, "\(result.diagnostics)")
        #expect(result.stdout.contains("\"name\":\"test.event\""))

        let requests = server.receivedRequests
        try #require(requests.count == 5)
        for index in [0, 2, 4] {
            let request = try #require(
                JSONSerialization.jsonObject(with: Data(requests[index].utf8)) as? [String: Any]
            )
            #expect(request["method"] as? String == "events.stream")
        }
        #expect(requests[1] == "auth stream-test-password")
        #expect(requests[3] == "auth stream-test-password")
    }

    @Test
    func ordinaryMultilineResponseIsNotTruncated() throws {
        let support = CMUXCLIErrorOutputRegressionTests()
        let cliPath = try support.bundledCLIPath()
        let root = try makeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("control.sock").path
        let response = "OK: Listing\nfirst row\nsecond row"
        let server = try UnixSocketResponder(path: socketPath, response: response)
        defer { server.stop() }
        let result = support.runProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "ping"],
            environment: environment(home: root, responseTimeout: "1"),
            timeout: 5
        )
        #expect(!result.timedOut, "\(result.diagnostics)")
        #expect(result.status == 0, "\(result.diagnostics)")
        #expect(result.stdout == response + "\n")
        #expect(server.receivedRequests == ["ping"])
    }

    private func makeHome() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/cmx-auth-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func environment(home: URL, responseTimeout: String) -> [String: String] {
        var result = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CMUX") }
        result["CFFIXED_USER_HOME"] = home.path
        result["HOME"] = home.path
        result["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = responseTimeout
        result["CMUX_CLI_SENTRY_DISABLED"] = "1"
        return result
    }
}
