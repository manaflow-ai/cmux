import Foundation
import Testing

extension CMUXCLIErrorOutputRegressionTests {
    @Test func paletteListTargetsAWindowWithoutPrefocusingIt() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-palette-\(UUID().uuidString.prefix(8)).sock"
        let windowID = UUID()
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: #"{"ok":true,"result":{"count":1,"commands":[{"id":"palette.demo","title":"Demo","subtitle":"Test","shortcut_hint":"⌘D","keywords":[],"dismiss_on_run":true,"arguments":[{"name":"path","type":"path","required":true,"allows_empty":false}]}]}}"#
        )
        defer { responder.stop() }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "--window", windowID.uuidString, "palette", "list"],
            environment: commandPaletteCLIEnvironment(),
            timeout: 5
        )

        #expect(!result.timedOut)
        #expect(result.status == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "palette.demo <path>\tDemo\t⌘D")
        let requests = responder.receivedRequests
        #expect(requests.count == 1)
        let request = try commandPaletteCLIRequest(try #require(requests.first))
        #expect(request["method"] as? String == "palette.list")
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["window_id"] as? String == windowID.uuidString)
    }

    @Test func paletteRunForwardsTheStableActionID() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-palrun-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: #"{"ok":true,"result":{"command":{"id":"palette.demo","title":"Demo","subtitle":"Test","shortcut_hint":null,"keywords":[],"dismiss_on_run":true}}}"#
        )
        defer { responder.stop() }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "palette", "run", "palette.demo"],
            environment: commandPaletteCLIEnvironment(),
            timeout: 5
        )

        #expect(!result.timedOut)
        #expect(result.status == 0)
        #expect(result.stdout.contains("palette.demo"))
        let request = try commandPaletteCLIRequest(try #require(responder.receivedRequests.first))
        #expect(request["method"] as? String == "palette.run")
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["command_id"] as? String == "palette.demo")
    }

    @Test func paletteRunForwardsNamedArgumentsWithoutActionSpecificParserCode() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-palargs-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: #"{"ok":true,"result":{"status":"completed","command":{"id":"palette.renameWorkspace","title":"Rename Workspace","subtitle":"Workspace","shortcut_hint":null,"keywords":[],"dismiss_on_run":false,"arguments":[{"name":"name","type":"string","required":true,"allows_empty":true}]}}}"#
        )
        defer { responder.stop() }

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "--socket", socketPath,
                "palette", "run", "palette.renameWorkspace",
                "--arg", "name=api=worker",
            ],
            environment: commandPaletteCLIEnvironment(),
            timeout: 5
        )

        #expect(!result.timedOut)
        #expect(result.status == 0)
        let request = try commandPaletteCLIRequest(try #require(responder.receivedRequests.first))
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["command_id"] as? String == "palette.renameWorkspace")
        #expect((params["arguments"] as? [String: String]) == ["name": "api=worker"])
    }

    @Test func vscodeShorthandDefaultsToTheCurrentDirectory() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-vscode-\(UUID().uuidString.prefix(8)).sock"
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vscode-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let response = "{\"ok\":true,\"result\":{\"accepted\":true,\"path\":\"\(directoryURL.path)\"}}"
        let responder = try UnixSocketResponder(path: socketPath, response: response)
        defer { responder.stop() }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "vscode", "."],
            environment: commandPaletteCLIEnvironment(),
            currentDirectoryURL: directoryURL,
            timeout: 5
        )

        #expect(!result.timedOut)
        #expect(result.status == 0)
        #expect(result.stdout.contains(directoryURL.path))
        let request = try commandPaletteCLIRequest(try #require(responder.receivedRequests.first))
        #expect(request["method"] as? String == "vscode.open")
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["path"] as? String == directoryURL.standardizedFileURL.path)
    }

    private func commandPaletteCLIEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        return environment
    }

    private func commandPaletteCLIRequest(_ line: String) throws -> [String: Any] {
        let data = try #require(line.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
