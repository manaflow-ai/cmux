import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    func testFullTUIStartsTheReservedCloudTerminalBeforeLaunchingItsClient() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-first-tui")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-first-tui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let probe = home.appendingPathComponent("client")
        try #"""
        #!/bin/sh
        printf '%s\n' '{"app":"cmux-tui","remote_protocol":1,"capabilities":["wireguard"]}'
        """#.write(to: probe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probe.path)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: home)
        }
        let machine = "vm-first-tui"
        let workspace = "11111111-1111-1111-1111-111111111111"
        let server = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line), let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = payload["params"] as? [String: Any] ?? [:]
            switch method {
            case "vm.cmux_remote_info":
                return self.v2Response(id: id, ok: true, result: [
                    "route": "ws://127.0.0.1:1337/v1/link", "session": "cloud", "trusted_carrier": true
                ])
            case "surface.catalog":
                XCTAssertEqual(params["ensure_linked"] as? Bool, true)
                return self.v2Response(id: id, ok: true, result: [
                    "machines": [["id": machine, "link_state": "connected", "remote_workspaces": [["id": "ws_first", "focused": true]]]],
                    "resources": []
                ])
            case "surface.new_terminal":
                XCTAssertEqual(params["machine"] as? String, machine)
                XCTAssertEqual(params["remote_workspace_id"] as? String, "ws_first")
                XCTAssertEqual(params["initial_workspace"] as? Bool, true)
                XCTAssertEqual(params["open"] as? Bool, false, "The full TUI owns its only local pane")
                XCTAssertEqual(params["suppress_welcome"] as? Bool, true)
                XCTAssertNil(params["command"], "Bootstrap cannot type or replace shell input")
                return self.v2Response(id: id, ok: true, result: ["terminal_id": "term_first", "remote_workspace_id": "ws_first"])
            case "workspace.create":
                XCTAssertTrue((params["initial_command"] as? String)?.contains("vm-tui-connect") == true)
                return self.v2Response(id: id, ok: true, result: ["workspace_id": workspace])
            case "workspace.cloud_vm_bind", "workspace.select", "workspace.activate", "workspace.focus":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                XCTFail("Unexpected method: \(method)")
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": method])
            }
        }
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["CMUX_TUI_CLIENT"] = probe.path
        environment["CMUX_CLOUD_WELCOME"] = "0"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["AppleLanguages"] = "(en)"
        let result = runProcess(executablePath: cliPath, arguments: [
            "--socket", socketPath, "--json", "vm", "tui", machine
        ], environment: environment, timeout: 10)
        wait(for: [server], timeout: 10)
        XCTAssertEqual(result.status, 0, result.stdout + result.stderr)
        let methods = state.commands.compactMap { self.jsonObject($0)?["method"] as? String }
        XCTAssertEqual(methods.filter { $0 == "surface.new_terminal" }.count, 1)
        XCTAssertEqual(methods.filter { $0 == "workspace.create" }.count, 1)
        let prepared = try XCTUnwrap(methods.firstIndex(of: "surface.new_terminal"))
        let launched = try XCTUnwrap(methods.firstIndex(of: "workspace.create"))
        XCTAssertLessThan(prepared, launched)
        XCTAssertFalse(methods.contains("surface.project"))
        XCTAssertFalse(methods.contains("surface.send_text"))
    }
}
