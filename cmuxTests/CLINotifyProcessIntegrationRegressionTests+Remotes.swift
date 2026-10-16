import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    func testRemotesValidationRejectsBadArgumentsBeforeRegistryRequests() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("remotes")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remotes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: home)
        }
        let state = MockSocketServerState()
        startDetachedMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line), let id = payload["id"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            return self.v2Response(id: id, ok: true, result: ["remotes": []])
        }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"

        for verb in ["list", "ls", "remove", "rm", "delete"] {
            let target = ["list", "ls"].contains(verb) ? [] : ["studio"]
            for (extra, diagnostic) in [
                ("unexpected", "unexpected argument"),
                ("--typo", "unknown flag")
            ] {
                let before = state.snapshot().count
                let result = runProcess(
                    executablePath: cliPath,
                    arguments: ["remotes", verb] + target + [extra],
                    environment: environment,
                    timeout: 5
                )
                XCTAssertFalse(result.timedOut, result.stderr)
                XCTAssertNotEqual(result.status, 0, result.stdout + result.stderr)
                XCTAssertTrue(result.stderr.contains(diagnostic), result.stderr)
                XCTAssertEqual(state.snapshot().count, before, "Rejected arguments must not send a registry request")
            }
        }

        // Successful calls prove the mock transport works and the terminator
        // keeps a target beginning with '-' intact through the real CLI path.
        let listed = runProcess(
            executablePath: cliPath,
            arguments: ["remotes", "ls", "--json"],
            environment: environment,
            timeout: 5
        )
        XCTAssertFalse(listed.timedOut, listed.stderr)
        XCTAssertEqual(listed.status, 0, listed.stderr)
        let listRequest = try XCTUnwrap(state.snapshot().last.flatMap(jsonObject))
        XCTAssertEqual(listRequest["method"] as? String, "remotes.list")

        for verb in ["remove", "rm", "delete"] {
            let removed = runProcess(
                executablePath: cliPath,
                arguments: ["remotes", verb, "--", "-private"],
                environment: environment,
                timeout: 5
            )
            XCTAssertFalse(removed.timedOut, removed.stderr)
            XCTAssertEqual(removed.status, 0, removed.stderr)
            let request = try XCTUnwrap(state.snapshot().last.flatMap(jsonObject))
            XCTAssertEqual(request["method"] as? String, "remotes.remove")
            let params = try XCTUnwrap(request["params"] as? [String: Any])
            XCTAssertEqual(params["target"] as? String, "-private")
        }
    }
}
