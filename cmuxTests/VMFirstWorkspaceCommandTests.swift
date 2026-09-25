import Foundation
import Testing

extension CMUXCLIErrorOutputRegressionTests {
    @Test func testFullTUIStartsTheReservedCloudTerminalBeforeLaunchingItsClient() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-first-tui-\(UUID().uuidString.prefix(8)).sock"
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-first-tui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let probe = home.appendingPathComponent("client")
        try #"""
        #!/bin/sh
        printf '%s\n' '{"app":"cmux-tui","remote_protocol":1,"capabilities":["wireguard"]}'
        """#.write(to: probe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probe.path)
        let machine = "vm-first-tui"
        let workspace = "11111111-1111-1111-1111-111111111111"
        let results: [[String: Any]] = [
            ["route": "ws://127.0.0.1:1337/v1/link", "session": "cloud", "trusted_carrier": true],
            ["machines": [["id": machine, "link_state": "connected", "remote_workspaces": [["id": "ws_first", "focused": true]]]], "resources": []],
            ["terminal_id": "term_first", "remote_workspace_id": "ws_first"],
            ["workspace_id": workspace],
            [:], [:]
        ]
        let responses = try results.map { result in
            String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
        }
        let server = try UnixSocketResponder(path: socketPath, responses: responses)
        defer { server.stop() }
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("CMUX_") { environment.removeValue(forKey: key) }
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_TUI_CLIENT"] = probe.path
        environment["CMUX_CLOUD_WELCOME"] = "0"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["AppleLanguages"] = "(en)"
        let result = runProcess(executablePath: cliPath, arguments: [
            "--socket", socketPath, "--json", "vm", "tui", machine
        ], environment: environment, timeout: 10)
        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status == 0, Comment(rawValue: result.diagnostics))
        let requests = try server.receivedRequests.map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let methods = requests.compactMap { $0["method"] as? String }
        #expect(methods == ["vm.cmux_remote_info", "surface.catalog", "surface.new_terminal", "workspace.create", "workspace.cloud_vm_bind", "workspace.select"])
        let catalog = try #require(requests.first { $0["method"] as? String == "surface.catalog" }?["params"] as? [String: Any])
        #expect(catalog["ensure_linked"] as? Bool == true)
        let prepared = try #require(requests.first { $0["method"] as? String == "surface.new_terminal" }?["params"] as? [String: Any])
        #expect(prepared["machine"] as? String == machine)
        #expect(prepared["remote_workspace_id"] as? String == "ws_first")
        #expect(prepared["initial_workspace"] as? Bool == true)
        #expect(prepared["open"] as? Bool == false, "The full TUI owns its only local pane")
        #expect(prepared["suppress_welcome"] as? Bool == true)
        #expect(prepared["command"] == nil, "Bootstrap cannot type or replace shell input")
        let launch = try #require(requests.first { $0["method"] as? String == "workspace.create" }?["params"] as? [String: Any])
        #expect((launch["initial_command"] as? String)?.contains("vm-tui-connect") == true)
    }
}
