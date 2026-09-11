import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Black-box coverage for `cmux vm layout export|apply` and `cmux vm env set|ls|rm`:
/// the real CLI binary runs against a mock control socket that plays the app's side of
/// `vm.exec`, `vm.env_set`, `layout.get`, `vm.tree`, and `vm.workspace_open`, so argument parsing,
/// local document validation (the JSON path in the error, zero socket traffic), the
/// base64 layout framing the in-VM shim consumes, the link-only env transport, dotenv parsing, saved-layout
/// wrapper detection, the outdated-shim guard, and the `--open` refresh/retry policy
/// are exercised exactly as an agent hits them. CLI-target code is not linked into
/// this bundle (see CLIVMTransferTests), so the static helpers are verified through
/// their observable command lines.
extension CLINotifyProcessIntegrationRegressionTests {
    /// Every decoded request the mock saw, in order, for assertions on method sequence
    /// and parameters (the raw `state` lines include the auth handshake).
    private final class VMLayoutEnvRequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [[String: Any]] = []

        func append(_ request: [String: Any]) {
            lock.lock()
            requests.append(request)
            lock.unlock()
        }

        func snapshot() -> [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        var methods: [String] { snapshot().compactMap { $0["method"] as? String } }

        func params(ofFirst method: String) -> [String: Any]? {
            snapshot().first { ($0["method"] as? String) == method }?["params"] as? [String: Any]
        }

        func commands() -> [String] {
            snapshot().compactMap { request in
                guard (request["method"] as? String) == "vm.exec" else { return nil }
                return (request["params"] as? [String: Any])?["command"] as? String
            }
        }
    }

    private final class VMLayoutEnvCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    private func vmLayoutEnvExecResponse(id: String, stdout: String, stderr: String = "", exitCode: Int = 0) -> String {
        v2Response(id: id, ok: true, result: ["exit_code": exitCode, "stdout": stdout, "stderr": stderr])
    }

    /// The base64 body of a `printf %s '<b64>' | base64 -d | …` command.
    private static func base64Payload(inCommand command: String) -> Data? {
        guard let start = command.range(of: "printf %s '"),
              let end = command.range(of: "' | base64 -d | ") else { return nil }
        return Data(base64Encoded: String(command[start.upperBound..<end.lowerBound]))
    }

    private func vmLayoutEnvEnvironment(socketPath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-layout-env-home-\(UUID().uuidString)")
        // The directory is created by the CLI only if needed; either way this
        // test owns its whole lifetime, including malformed-input cases.
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        return environment
    }

    private func vmLayoutEnvTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vm-\(name)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A mock that answers `vm.exec` through `onExec` and rejects every other method.
    private func startVMExecMock(
        listenerFD: Int32,
        state: MockSocketServerState,
        log: VMLayoutEnvRequestLog,
        onExec: @escaping @Sendable (_ id: String, _ command: String) -> String
    ) -> XCTestExpectation {
        startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            log.append(request)
            guard method == "vm.exec",
                  let params = request["params"] as? [String: Any],
                  let command = params["command"] as? String else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
            return onExec(id, command)
        }
    }

    private static let sampleLayoutNode: [String: Any] = [
        "direction": "horizontal",
        "split": 0.6,
        "children": [
            ["pane": ["surfaces": [["type": "terminal", "name": "agent", "command": "claude", "cwd": "work/app"]]]],
            [
                "direction": "vertical",
                "children": [
                    ["pane": ["surfaces": [["type": "terminal", "command": "bun test --watch"]]]],
                    ["pane": ["surfaces": [["type": "browser", "url": "http://localhost:3000"]]]],
                ],
            ],
        ],
    ]

    // MARK: - vm env

    private struct VMEnvProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    /// Like `runProcess`, with bytes on stdin — `cmux vm env set <m> -` reads assignments
    /// there so values never sit in the caller's argv or history.
    private func runProcessWithInput(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String,
        timeout: TimeInterval
    ) -> VMEnvProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return VMEnvProcessResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }
        stdinPipe.fileHandleForWriting.write(Data(standardInput.utf8))
        try? stdinPipe.fileHandleForWriting.close()
        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }
        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return VMEnvProcessResult(
            status: process.isRunning ? SIGKILL : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    /// The app's side of `vm.env_set`: names back, never values. Any `vm.exec` is a test
    /// failure — values must not ride the control plane.
    private func startVMEnvSetMock(
        listenerFD: Int32,
        state: MockSocketServerState,
        log: VMLayoutEnvRequestLog
    ) -> XCTestExpectation {
        startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            log.append(request)
            let params = (request["params"] as? [String: Any]) ?? [:]
            guard method == "vm.env_set",
                  let machine = params["id"] as? String,
                  let entries = params["entries"] as? [[String: Any]] else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
            let keys = entries.compactMap { $0["key"] as? String }
            return self.v2Response(id: id, ok: true, result: [
                "machine": machine, "keys": keys, "count": keys.count, "path": "/root/.config/cmux/env",
            ])
        }
    }

    /// `KEY=VALUE` per entry of the first `vm.env_set` the mock saw, in request order.
    private func vmEnvSetEntryLines(_ log: VMLayoutEnvRequestLog) -> [String] {
        let entries = (log.params(ofFirst: "vm.env_set")?["entries"] as? [[String: Any]]) ?? []
        return entries.map { "\(($0["key"] as? String) ?? "?")=\(($0["value"] as? String) ?? "?")" }
    }

    func testVMEnvSetDeliversEntriesOverTheMachineLinkNeverExec() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-env-set")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMLayoutEnvRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let serverHandled = startVMEnvSetMock(listenerFD: listenerFD, state: state, log: log)

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "env", "set", "brave-otter", "A=1", "B=x y"],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        // One request, the link-backed method, typed entries — and no exec anywhere.
        XCTAssertEqual(log.methods, ["vm.env_set"], log.methods.description)
        XCTAssertEqual(log.params(ofFirst: "vm.env_set")?["id"] as? String, "brave-otter")
        XCTAssertEqual(vmEnvSetEntryLines(log), ["A=1", "B=x y"])
        XCTAssertTrue(log.commands().isEmpty, "values must never ride vm.exec: \(log.commands())")
        // Values are secrets: the summary names keys only.
        XCTAssertTrue(result.stdout.contains("OK set 2 variables on brave-otter: A, B"), result.stdout)
        XCTAssertFalse(result.stdout.contains("x y"), result.stdout)
    }

    func testVMEnvSetReadsDotenvFilesAndStdinLiterally() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-env-file")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMLayoutEnvRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let tempDir = try vmLayoutEnvTempDir("env-file")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let envFile = tempDir.appendingPathComponent("dev.env")
        try """
        # database
        export DATABASE_URL="postgres://localhost/app"

        TOKEN='abc def'
        PLAIN=hello # trailing comment
        QUOTED_LITERAL="keep" # trailing comment
        SPACEY="  padded  "
        EMPTY=
        """.write(to: envFile, atomically: true, encoding: .utf8)

        let serverHandled = startVMEnvSetMock(listenerFD: listenerFD, state: state, log: log)

        let result = runProcessWithInput(
            executablePath: cliPath,
            arguments: ["vm", "env", "set", "brave-otter", "--from-file", envFile.path, "PLAIN=argv", "Q='x'", "-", "FROM_STDIN=argv-after-stdin"],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            standardInput: "FROM_STDIN=\"two words\"\n# ignored\nexport SECOND=2\n",
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(log.methods, ["vm.env_set"], log.methods.description)
        // dotenv rules applied on the Mac (comments, `export`, matching quotes, inline
        // comment); every value reaches the app byte for byte, quotes and padding included.
        XCTAssertEqual(vmEnvSetEntryLines(log), [
            "DATABASE_URL=postgres://localhost/app",
            "TOKEN=abc def",
            "PLAIN=argv",
            "QUOTED_LITERAL=keep",
            "SPACEY=  padded  ",
            "EMPTY=",
            "Q='x'",
            "FROM_STDIN=argv-after-stdin",
            "SECOND=2",
        ])
        XCTAssertTrue(result.stdout.contains("OK set 9 variables on brave-otter"), result.stdout)
        XCTAssertFalse(result.stdout.contains("postgres://"), "values never echo back: \(result.stdout)")
    }

    func testVMEnvSetRejectsInvalidKeysWithoutTouchingTheSocket() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-env-bad")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "env", "set", "brave-otter", "1BAD=value"],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            timeout: 30
        )

        XCTAssertEqual(result.status, 2, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertTrue(result.stderr.contains("invalid variable name '1BAD'"), result.stderr)
        var connection = pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(Darwin.poll(&connection, 1, 0), 0, "a rejected assignment must not connect to the socket")
    }

    func testVMEnvListForwardsFlagsAndPrintsStdoutVerbatim() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-env-ls")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMLayoutEnvRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let listing = "{\"path\":\"/root/.config/cmux/env\",\"keys\":[\"A\",\"B\"]}\n"
        let serverHandled = startVMExecMock(listenerFD: listenerFD, state: state, log: log) { id, _ in
            self.vmLayoutEnvExecResponse(id: id, stdout: listing)
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "env", "ls", "brave-otter", "--json"],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(log.commands(), ["cmux env ls --json"])
        XCTAssertEqual(result.stdout, listing, "the shim's listing is printed byte for byte")
    }

    func testVMEnvRemoveForwardsKeys() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-env-rm")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMLayoutEnvRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let serverHandled = startVMExecMock(listenerFD: listenerFD, state: state, log: log) { id, _ in
            self.vmLayoutEnvExecResponse(id: id, stdout: "")
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "env", "rm", "brave-otter", "A", "DATABASE_URL"],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(log.commands(), ["cmux env rm A DATABASE_URL"])
        XCTAssertTrue(result.stdout.contains("OK removed 2 variables on brave-otter: A, DATABASE_URL"), result.stdout)
    }

    // MARK: - vm layout

    func testVMLayoutExportForwardsWorkspaceAndRawAndPrintsJSON() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-layout-export")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMLayoutEnvRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let exported = "{\"version\":1,\"screen_id\":\"screen_1\",\"root\":{\"kind\":\"leaf\",\"pane_id\":\"pane_1\",\"tab_ids\":[]}}\n"
        let serverHandled = startVMExecMock(listenerFD: listenerFD, state: state, log: log) { id, _ in
            self.vmLayoutEnvExecResponse(id: id, stdout: exported)
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "layout", "export", "brave-otter", "ws_1", "--raw"],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(log.commands(), ["cmux layout export --json --workspace ws_1 --raw"])
        XCTAssertEqual(result.stdout, exported)
        let timeout = try XCTUnwrap(log.params(ofFirst: "vm.exec")?["timeout_ms"] as? Int)
        XCTAssertGreaterThanOrEqual(timeout, 30_000)
    }

    func testVMLayoutApplySendsTheDocumentAndForwardsTargetFlags() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-layout-apply")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMLayoutEnvRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let tempDir = try vmLayoutEnvTempDir("layout-apply")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let layoutFile = tempDir.appendingPathComponent("dev.json")
        let documentBytes = try JSONSerialization.data(withJSONObject: Self.sampleLayoutNode, options: [.sortedKeys])
        try documentBytes.write(to: layoutFile)

        let applied = """
        {"workspace_id":"ws_1","workspace_name":"dev","panes":[{"pane_id":"pane_1","surfaces":[{"type":"terminal","terminal_id":"term_1","tab_id":"tab_1"}]},{"pane_id":"pane_2","surfaces":[{"type":"terminal","terminal_id":"term_2","tab_id":"tab_2"}]},{"pane_id":"pane_3","surfaces":[{"type":"browser","browser_id":"browser_1","tab_id":"tab_3"}]}],"warnings":["project surfaces are Mac-only; skipped 0"]}

        """
        let serverHandled = startVMExecMock(listenerFD: listenerFD, state: state, log: log) { id, _ in
            self.vmLayoutEnvExecResponse(id: id, stdout: applied)
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "layout", "apply", "brave-otter", layoutFile.path, "--workspace", "ws_1", "--name", "dev"],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(log.methods, ["vm.exec"], "no open without --open")
        let command = try XCTUnwrap(log.commands().first)
        XCTAssertTrue(command.hasSuffix("| base64 -d | cmux layout apply --json --workspace ws_1 --name dev -"), command)
        XCTAssertEqual(Self.base64Payload(inCommand: command), documentBytes, "the file travels byte for byte")
        XCTAssertTrue(result.stdout.contains("OK workspace=ws_1 name=dev panes=3 surfaces=3 machine=brave-otter"), result.stdout)
        XCTAssertTrue(result.stdout.contains("cmux vm workspace open brave-otter ws_1"), "hint names the manual open: \(result.stdout)")
        XCTAssertTrue(result.stderr.contains("warning: project surfaces are Mac-only"), result.stderr)
    }

    func testVMLayoutApplyFromSavedLayoutRefreshesRetriesAndOpens() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-layout-open")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMLayoutEnvRequestLog()
        let openAttempts = VMLayoutEnvCounter()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let localWorkspaceID = UUID().uuidString

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            log.append(request)
            let params = (request["params"] as? [String: Any]) ?? [:]
            switch method {
            case "layout.get":
                guard (params["name"] as? String) == "dev" else {
                    return self.v2Response(id: id, ok: false, error: ["code": "not_found", "message": "Layout not found"])
                }
                // What `cmux layout get dev` returns: the saved-layout wrapper.
                let saved: [String: Any] = [
                    "name": "dev",
                    "description": "agent left, tests right",
                    "workspace": ["cwd": "~/src/app", "layout": Self.sampleLayoutNode],
                ]
                return self.v2Response(id: id, ok: true, result: saved)
            case "vm.exec":
                return self.vmLayoutEnvExecResponse(
                    id: id,
                    stdout: "{\"workspace_id\":\"ws_9\",\"workspace_name\":\"dev\",\"panes\":[{\"pane_id\":\"pane_1\",\"surfaces\":[{\"type\":\"terminal\",\"terminal_id\":\"term_1\",\"tab_id\":\"tab_1\"}]}],\"warnings\":[]}\n"
                )
            case "vm.tree":
                return self.v2Response(id: id, ok: true, result: ["machines": [], "resources": [], "projections": []])
            case "vm.workspace_open":
                // The catalog has not seen the new workspace on the first try.
                if openAttempts.next() == 1 {
                    return self.v2Response(id: id, ok: false, error: ["code": "not_ready", "message": "Nothing to open: workspace ws_9 is empty."])
                }
                return self.v2Response(id: id, ok: true, result: [
                    "machine": "brave-otter",
                    "remote_workspace_id": "ws_9",
                    "remote_workspace_name": "dev",
                    "workspace_id": localWorkspaceID,
                    "surface_ids": [UUID().uuidString],
                    "opened": 1,
                    "here": false,
                ])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "layout", "apply", "brave-otter", "--from-saved", "dev", "--open"],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            timeout: 45
        )

        wait(for: [serverHandled], timeout: 45)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(
            log.methods,
            ["layout.get", "vm.exec", "vm.tree", "vm.workspace_open", "vm.workspace_open"],
            "saved layout read locally, applied, catalog refreshed, then opened (one not-found retry)"
        )

        // The wrapper is forwarded as-is: the shim reads `workspace.layout` itself.
        let command = try XCTUnwrap(log.commands().first)
        XCTAssertTrue(command.hasSuffix("| base64 -d | cmux layout apply --json -"), command)
        let forwarded = try XCTUnwrap(Self.base64Payload(inCommand: command))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: forwarded) as? [String: Any])
        XCTAssertEqual(object["name"] as? String, "dev")
        let workspace = try XCTUnwrap(object["workspace"] as? [String: Any])
        XCTAssertEqual(workspace["cwd"] as? String, "~/src/app")
        XCTAssertNotNil(workspace["layout"] as? [String: Any])

        let refresh = try XCTUnwrap(log.params(ofFirst: "vm.tree"))
        XCTAssertEqual(refresh["id"] as? String, "brave-otter")
        XCTAssertEqual(refresh["refresh"] as? Bool, true)
        let open = try XCTUnwrap(log.params(ofFirst: "vm.workspace_open"))
        XCTAssertEqual(open["id"] as? String, "brave-otter")
        XCTAssertEqual(open["workspace_id"] as? String, "ws_9")

        XCTAssertTrue(result.stdout.contains("OK workspace=ws_9 name=dev panes=1 surfaces=1 machine=brave-otter"), result.stdout)
        XCTAssertTrue(result.stdout.contains("OK opened workspace=\(localWorkspaceID) opened=1 machine=brave-otter"), result.stdout)
    }

    func testVMLayoutApplyOpenGivesUpWithTheManualCommand() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-layout-open-fail")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMLayoutEnvRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let tempDir = try vmLayoutEnvTempDir("layout-open-fail")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let layoutFile = tempDir.appendingPathComponent("one.json")
        try JSONSerialization.data(withJSONObject: ["pane": ["surfaces": [["type": "terminal"]]]]).write(to: layoutFile)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            log.append(request)
            switch method {
            case "vm.exec":
                return self.vmLayoutEnvExecResponse(id: id, stdout: "{\"workspace_id\":\"ws_7\",\"workspace_name\":\"one\",\"panes\":[],\"warnings\":[]}\n")
            case "vm.tree":
                return self.v2Response(id: id, ok: true, result: ["machines": [], "resources": [], "projections": []])
            case "vm.workspace_open":
                // The Mac keeps seeing it as empty: every attempt says so.
                return self.v2Response(id: id, ok: true, result: ["machine": "brave-otter", "remote_workspace_id": "ws_7", "opened": 0, "empty": true])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "layout", "apply", "brave-otter", layoutFile.path, "--open"],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            timeout: 60
        )

        wait(for: [serverHandled], timeout: 60)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(log.methods.filter { $0 == "vm.workspace_open" }.count, 5, "five attempts, one second apart: \(log.methods)")
        XCTAssertTrue(result.stderr.contains("ws_7"), result.stderr)
        XCTAssertTrue(result.stderr.contains("cmux vm workspace open brave-otter ws_7"), result.stderr)
    }

    func testVMLayoutApplyRejectsInvalidDocumentsBeforeTouchingTheMachine() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-layout-invalid")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let tempDir = try vmLayoutEnvTempDir("layout-invalid")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cases: [(name: String, document: Any, expectedPath: String, expectedReason: String)] = [
            (
                "one-child",
                ["direction": "horizontal", "children": [["pane": ["surfaces": [["type": "terminal"]]]]]],
                "$.children",
                "exactly 2 children"
            ),
            (
                "nested-bad-type",
                [
                    "layout": [
                        "direction": "vertical",
                        "children": [
                            ["pane": ["surfaces": [["type": "terminal"]]]],
                            ["pane": ["surfaces": [["type": "tmux"]]]],
                        ],
                    ],
                ],
                "$.layout.children[1].pane.surfaces[0].type",
                "'type' must be"
            ),
            (
                "both-keys",
                ["pane": ["surfaces": [["type": "terminal"]]], "direction": "horizontal", "children": []],
                "$",
                "both 'pane' and 'direction'"
            ),
            (
                "no-layout",
                ["name": "dev", "workspace": ["cwd": "~"]],
                "$",
                "no layout found"
            ),
            (
                "split-too-small",
                ["direction": "horizontal", "split": 0.01, "children": [["pane": ["surfaces": [["type": "terminal"]]]], ["pane": ["surfaces": [["type": "terminal"]]]]]],
                "$.split", "0.1–0.9"
            ),
            (
                "split-too-large",
                ["direction": "horizontal", "split": 0.99, "children": [["pane": ["surfaces": [["type": "terminal"]]]], ["pane": ["surfaces": [["type": "terminal"]]]]]],
                "$.split", "0.1–0.9"
            ),
            (
                "empty-surfaces",
                ["workspace": ["layout": ["pane": ["surfaces": []]]]],
                "$.workspace.layout.pane.surfaces",
                "non-empty array"
            ),
        ]

        for testCase in cases {
            let file = tempDir.appendingPathComponent("\(testCase.name).json")
            try JSONSerialization.data(withJSONObject: testCase.document).write(to: file)
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["vm", "layout", "apply", "brave-otter", file.path],
                environment: vmLayoutEnvEnvironment(socketPath: socketPath),
                timeout: 30
            )
            XCTAssertEqual(result.status, 2, "\(testCase.name): stdout=\(result.stdout) stderr=\(result.stderr)")
            XCTAssertTrue(result.stderr.contains("invalid layout document"), "\(testCase.name): \(result.stderr)")
            XCTAssertTrue(result.stderr.contains(" at \(testCase.expectedPath)"), "\(testCase.name) names the path: \(result.stderr)")
            XCTAssertTrue(result.stderr.contains(testCase.expectedReason), "\(testCase.name) says why: \(result.stderr)")
        }

        let notJSON = tempDir.appendingPathComponent("not.json")
        try Data("{".utf8).write(to: notJSON)
        let broken = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "layout", "apply", "brave-otter", notJSON.path],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            timeout: 30
        )
        XCTAssertEqual(broken.status, 2, broken.stderr)
        XCTAssertTrue(broken.stderr.contains("not valid JSON at $"), broken.stderr)

        let conflict = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "layout", "apply", "brave-otter", "--from-saved", "must-not-be-read", "--workspace", "ws_empty", "--name", "conflict"],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            timeout: 5
        )
        XCTAssertEqual(conflict.status, 2, conflict.stderr)
        var connection = pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(Darwin.poll(&connection, 1, 0), 0, "invalid documents and targets must not connect to the socket")
    }

    func testVMLayoutApplyExplainsAnOutdatedShim() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("vm-layout-old-shim")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMLayoutEnvRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let tempDir = try vmLayoutEnvTempDir("layout-old-shim")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let layoutFile = tempDir.appendingPathComponent("one.json")
        try JSONSerialization.data(withJSONObject: ["pane": ["surfaces": [["type": "terminal"]]]]).write(to: layoutFile)

        // An old shim knows no `layout` word and falls through to cmux-tui, which
        // rejects the resource scope.
        let serverHandled = startVMExecMock(listenerFD: listenerFD, state: state, log: log) { id, _ in
            self.vmLayoutEnvExecResponse(id: id, stdout: "", stderr: "error: unknown resource scope \"layout\"\n", exitCode: 2)
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "layout", "apply", "brave-otter", layoutFile.path],
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertNotEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertTrue(result.stderr.contains("predates layout support"), result.stderr)
        XCTAssertTrue(result.stderr.contains("cmux vm tree brave-otter --refresh"), result.stderr)
    }

    // MARK: - vm exec --timeout, pause/resume, terminal wait-exit/output, workspace new --reuse, per-verb help

    /// A mock that routes every v2 method through `respond` (nil → "unexpected method"),
    /// for the verbs whose contract is the method and its params, not an exec command line.
    private func startVMMethodMock(
        listenerFD: Int32,
        state: MockSocketServerState,
        log: VMLayoutEnvRequestLog,
        respond: @escaping @Sendable (_ method: String, _ params: [String: Any]) -> [String: Any]?
    ) -> XCTestExpectation {
        startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            log.append(request)
            let params = (request["params"] as? [String: Any]) ?? [:]
            guard let result = respond(method, params) else {
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
            return self.v2Response(id: id, ok: true, result: result)
        }
    }

    /// One `cmux vm …` invocation against `startVMMethodMock`; returns the process result
    /// and every request the mock saw (the auth handshake is not a request).
    private func runVMCommandAgainstMock(
        _ name: String,
        arguments: [String],
        respond: @escaping @Sendable (_ method: String, _ params: [String: Any]) -> [String: Any]?
    ) throws -> (result: ProcessRunResult, log: VMLayoutEnvRequestLog) {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath(name)
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMLayoutEnvRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let serverHandled = startVMMethodMock(listenerFD: listenerFD, state: state, log: log, respond: respond)
        let result = runProcess(
            executablePath: cliPath,
            arguments: arguments,
            environment: vmLayoutEnvEnvironment(socketPath: socketPath),
            timeout: 30
        )
        wait(for: [serverHandled], timeout: 30)
        XCTAssertFalse(result.timedOut, "\(arguments) timed out: \(result.stderr)")
        return (result, log)
    }

    func testVMExecTimeoutFlagBecomesTimeoutMsAndStaysOutOfTheCommand() throws {
        let (result, log) = try runVMCommandAgainstMock(
            "vm-exec-timeout",
            // The flag sits before `--`; the same word after `--` is command text.
            arguments: ["vm", "exec", "--timeout", "120", "brave-otter", "--", "sh", "-c", "sleep 1; echo --timeout done"]
        ) { method, _ in
            method == "vm.exec" ? ["exit_code": 0, "stdout": "done\n", "stderr": ""] : nil
        }

        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(log.methods, ["vm.exec"], log.methods.description)
        let params = log.params(ofFirst: "vm.exec")
        XCTAssertEqual(params?["id"] as? String, "brave-otter")
        XCTAssertEqual(params?["timeout_ms"] as? Int, 120_000)
        XCTAssertEqual(params?["command"] as? String, "sh -c 'sleep 1; echo --timeout done'")
        XCTAssertEqual(result.stdout, "done\n")
    }

    func testVMExecDefaultsToThirtySecondsAndRejectsOutOfRangeTimeouts() throws {
        let (defaulted, defaultLog) = try runVMCommandAgainstMock(
            "vm-exec-default",
            arguments: ["vm", "exec", "brave-otter", "--", "true"]
        ) { method, _ in
            method == "vm.exec" ? ["exit_code": 0, "stdout": "", "stderr": ""] : nil
        }
        XCTAssertEqual(defaulted.status, 0, "stdout=\(defaulted.stdout) stderr=\(defaulted.stderr)")
        XCTAssertEqual(defaultLog.params(ofFirst: "vm.exec")?["timeout_ms"] as? Int, 30_000)

        for bad in ["0", "901", "2m"] {
            let (rejected, rejectedLog) = try runVMCommandAgainstMock(
                "vm-exec-bad-timeout",
                arguments: ["vm", "exec", "--timeout", bad, "brave-otter", "--", "true"]
            ) { _, _ in nil }
            XCTAssertNotEqual(rejected.status, 0, "--timeout \(bad) must be rejected: stdout=\(rejected.stdout)")
            XCTAssertTrue(rejected.stderr.contains("between 1 and 900"), rejected.stderr)
            XCTAssertTrue(rejectedLog.methods.isEmpty, "a rejected timeout must not reach the app: \(rejectedLog.methods)")
        }
    }

    func testVMPauseAndResumeSendTheLifecycleMethods() throws {
        let (paused, pauseLog) = try runVMCommandAgainstMock(
            "vm-pause",
            arguments: ["vm", "pause", "brave-otter"]
        ) { method, params in
            method == "vm.pause" ? ["id": params["id"] ?? "?", "status": "paused"] : nil
        }
        XCTAssertEqual(paused.status, 0, "stdout=\(paused.stdout) stderr=\(paused.stderr)")
        XCTAssertEqual(pauseLog.methods, ["vm.pause"], pauseLog.methods.description)
        XCTAssertEqual(pauseLog.params(ofFirst: "vm.pause")?["id"] as? String, "brave-otter")
        XCTAssertTrue(paused.stdout.contains("OK brave-otter paused (status=paused)"), paused.stdout)
        XCTAssertTrue(paused.stdout.contains("cmux vm resume brave-otter"), paused.stdout)

        let (resumed, resumeLog) = try runVMCommandAgainstMock(
            "vm-resume",
            arguments: ["vm", "resume", "brave-otter", "--json"]
        ) { method, params in
            method == "vm.resume" ? ["id": params["id"] ?? "?", "status": "running"] : nil
        }
        XCTAssertEqual(resumed.status, 0, "stdout=\(resumed.stdout) stderr=\(resumed.stderr)")
        XCTAssertEqual(resumeLog.methods, ["vm.resume"], resumeLog.methods.description)
        let payload = jsonObject(resumed.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(payload?["status"] as? String, "running", resumed.stdout)
        XCTAssertEqual(payload?["id"] as? String, "brave-otter", resumed.stdout)

        // A provider that cannot pause is a plain error, not a stack of JSON.
        let (unsupported, _) = try runVMCommandAgainstMock(
            "vm-pause-unsupported",
            arguments: ["vm", "pause", "brave-otter"]
        ) { _, _ in nil }
        XCTAssertNotEqual(unsupported.status, 0, unsupported.stdout)
        XCTAssertTrue(unsupported.stderr.contains("Unexpected method vm.pause"), unsupported.stderr)
    }

    func testVMTerminalWaitExitReportsTheOutcomeAndFailsWhilePending() throws {
        let (exited, exitLog) = try runVMCommandAgainstMock(
            "vm-wait-exit",
            arguments: ["vm", "terminal", "wait-exit", "brave-otter", "term_7", "--timeout", "5"]
        ) { method, _ in
            guard method == "vm.terminal_wait_exit" else { return nil }
            return [
                "state": "exited", "terminal_id": "term_7", "lifecycle": "exited",
                "outcome": ["kind": "exit", "code": 3], "exited_at": 1_725_000_000_000,
            ]
        }
        // Exit status 0: the wait succeeded (the process finished). Its own code is in the line.
        XCTAssertEqual(exited.status, 0, "stdout=\(exited.stdout) stderr=\(exited.stderr)")
        XCTAssertEqual(exited.stdout, "exited code=3\n")
        XCTAssertEqual(exitLog.methods, ["vm.terminal_wait_exit"], exitLog.methods.description)
        let params = exitLog.params(ofFirst: "vm.terminal_wait_exit")
        XCTAssertEqual(params?["id"] as? String, "brave-otter")
        XCTAssertEqual(params?["terminal_id"] as? String, "term_7")
        XCTAssertEqual(params?["timeout_ms"] as? Int, 5_000)

        let (signaled, _) = try runVMCommandAgainstMock(
            "vm-wait-exit-signal",
            arguments: ["vm", "terminal", "wait-exit", "brave-otter", "term_7"]
        ) { method, _ in
            method == "vm.terminal_wait_exit"
                ? ["state": "exited", "outcome": ["kind": "signal", "signal": 9, "core_dumped": false]]
                : nil
        }
        XCTAssertEqual(signaled.status, 0, signaled.stderr)
        XCTAssertEqual(signaled.stdout, "exited signal=9\n")

        let (pending, pendingLog) = try runVMCommandAgainstMock(
            "vm-wait-exit-pending",
            arguments: ["vm", "terminal", "wait-exit", "brave-otter", "term_7", "--timeout", "0.5"]
        ) { method, _ in
            method == "vm.terminal_wait_exit" ? ["state": "pending", "terminal_id": "term_7", "lifecycle": "running"] : nil
        }
        XCTAssertNotEqual(pending.status, 0, "a still-running process is a failed wait: stdout=\(pending.stdout)")
        XCTAssertEqual(pending.stdout, "pending\n")
        XCTAssertTrue(pending.stderr.contains("still running"), pending.stderr)
        XCTAssertEqual(pendingLog.params(ofFirst: "vm.terminal_wait_exit")?["timeout_ms"] as? Int, 500)

        // `--pattern` is `wait`'s; `--timeout` is shared by both wait verbs.
        let (misused, misusedLog) = try runVMCommandAgainstMock(
            "vm-wait-exit-misuse",
            arguments: ["vm", "terminal", "wait-exit", "brave-otter", "term_7", "--pattern", "x"]
        ) { _, _ in nil }
        XCTAssertNotEqual(misused.status, 0, misused.stdout)
        XCTAssertTrue(misused.stderr.contains("--pattern belongs to `wait`"), misused.stderr)
        XCTAssertTrue(misusedLog.methods.isEmpty, misusedLog.methods.description)
    }

    func testVMTerminalOutputPrintsTextAndForwardsOffsets() throws {
        let (human, humanLog) = try runVMCommandAgainstMock(
            "vm-terminal-output",
            arguments: ["vm", "terminal", "output", "brave-otter", "term_7", "--after", "100", "--max-bytes", "2048"]
        ) { method, _ in
            method == "vm.terminal_output"
                ? ["text": "hello\nworld\n", "start_offset": 100, "next_offset": 112, "complete": true]
                : nil
        }
        XCTAssertEqual(human.status, 0, "stdout=\(human.stdout) stderr=\(human.stderr)")
        // Human output is the text, byte for byte — no banner, no added newline.
        XCTAssertEqual(human.stdout, "hello\nworld\n")
        XCTAssertEqual(humanLog.methods, ["vm.terminal_output"], humanLog.methods.description)
        let params = humanLog.params(ofFirst: "vm.terminal_output")
        XCTAssertEqual(params?["id"] as? String, "brave-otter")
        XCTAssertEqual(params?["terminal_id"] as? String, "term_7")
        XCTAssertEqual(params?["after"] as? Int, 100)
        XCTAssertEqual(params?["max_bytes"] as? Int, 2_048)

        let (json, jsonLog) = try runVMCommandAgainstMock(
            "vm-terminal-output-json",
            arguments: ["vm", "terminal", "output", "brave-otter", "term_7", "--json"]
        ) { method, _ in
            method == "vm.terminal_output"
                ? ["text": "partial", "start_offset": 0, "next_offset": 7, "complete": false]
                : nil
        }
        XCTAssertEqual(json.status, 0, "stdout=\(json.stdout) stderr=\(json.stderr)")
        let payload = jsonObject(json.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(payload?["next_offset"] as? Int, 7, json.stdout)
        XCTAssertEqual(payload?["complete"] as? Bool, false, json.stdout)
        // No offset flags → the whole log from the start; nothing is invented client-side.
        let jsonParams = jsonLog.params(ofFirst: "vm.terminal_output")
        XCTAssertNil(jsonParams?["after"])
        XCTAssertNil(jsonParams?["max_bytes"])

        let (bad, badLog) = try runVMCommandAgainstMock(
            "vm-terminal-output-bad",
            arguments: ["vm", "terminal", "output", "brave-otter", "term_7", "--after", "-1"]
        ) { _, _ in nil }
        XCTAssertNotEqual(bad.status, 0, bad.stdout)
        XCTAssertTrue(bad.stderr.contains("--after must be a non-negative offset"), bad.stderr)
        XCTAssertTrue(badLog.methods.isEmpty, badLog.methods.description)
    }

    func testVMWorkspaceNewReuseSendsTheFlagAndMarksAnExistingWorkspace() throws {
        let (reused, reuseLog) = try runVMCommandAgainstMock(
            "vm-workspace-reuse",
            arguments: ["vm", "workspace", "new", "brave-otter", "--name", "tests", "--reuse"]
        ) { method, params in
            guard method == "vm.workspace_new" else { return nil }
            return [
                "machine": params["id"] ?? "?", "name": params["name"] ?? "?", "existing": true,
                "remote_workspace_id": "ws_42", "workspace_id": "3F1C7A2E-0000-4000-8000-000000000042",
            ]
        }
        XCTAssertEqual(reused.status, 0, "stdout=\(reused.stdout) stderr=\(reused.stderr)")
        XCTAssertEqual(reuseLog.methods, ["vm.workspace_new"], reuseLog.methods.description)
        let params = reuseLog.params(ofFirst: "vm.workspace_new")
        XCTAssertEqual(params?["id"] as? String, "brave-otter")
        XCTAssertEqual(params?["name"] as? String, "tests")
        XCTAssertEqual(params?["reuse"] as? Bool, true)
        XCTAssertTrue(reused.stdout.contains("remote_workspace=ws_42 machine=brave-otter (existing)"), reused.stdout)

        // Without --reuse the app creates; the request must not carry the flag at all.
        let (created, createLog) = try runVMCommandAgainstMock(
            "vm-workspace-create",
            arguments: ["vm", "workspace", "new", "brave-otter", "--name", "tests"]
        ) { method, _ in
            method == "vm.workspace_new"
                ? ["existing": false, "remote_workspace_id": "ws_43", "workspace_id": "3F1C7A2E-0000-4000-8000-000000000043"]
                : nil
        }
        XCTAssertEqual(created.status, 0, created.stderr)
        XCTAssertNil(createLog.params(ofFirst: "vm.workspace_new")?["reuse"])
        XCTAssertFalse(created.stdout.contains("(existing)"), created.stdout)

        // Reuse needs a name to look for; that is a usage error before any request.
        let (nameless, namelessLog) = try runVMCommandAgainstMock(
            "vm-workspace-reuse-nameless",
            arguments: ["vm", "workspace", "new", "brave-otter", "--reuse"]
        ) { _, _ in nil }
        XCTAssertNotEqual(nameless.status, 0, nameless.stdout)
        XCTAssertTrue(nameless.stderr.contains("--reuse needs --name"), nameless.stderr)
        XCTAssertTrue(namelessLog.methods.isEmpty, namelessLog.methods.description)
    }

    func testVMResizeIsNoLongerAVerb() throws {
        let (result, log) = try runVMCommandAgainstMock(
            "vm-resize-gone",
            arguments: ["vm", "resize", "brave-otter", "--disk", "40"]
        ) { _, _ in nil }
        XCTAssertNotEqual(result.status, 0, result.stdout)
        XCTAssertTrue(result.stderr.contains("Usage: cmux vm <"), result.stderr)
        XCTAssertFalse(result.stderr.contains("resize"), "resize must not be advertised: \(result.stderr)")
        XCTAssertTrue(result.stderr.contains("pause|resume"), result.stderr)
        XCTAssertTrue(log.methods.isEmpty, "an unknown verb must not reach the app: \(log.methods)")
    }

    func testVMVerbHelpPrintsThatVerbsUsageWithoutASocket() throws {
        let cliPath = try bundledCLIPath()
        // Help never resolves a socket: point at a path nothing listens on.
        let environment = vmLayoutEnvEnvironment(socketPath: makeSocketPath("vm-help-no-socket"))
        let cases: [(arguments: [String], expected: [String], forbidden: [String])] = [
            (["vm", "terminal", "--help"], ["cmux vm terminal", "wait-exit <machine> <terminal-id>", "output <machine> <terminal-id>"], ["cmux vm new"]),
            (["cloud", "exec", "-h"], ["cmux vm exec", "[--timeout <seconds>]", "1…900"], ["cmux vm new"]),
            (["vm", "pause", "--help"], ["cmux vm pause", "Park the machine", "cmux vm resume <machine>"], []),
            (["vm", "workspace", "--help"], ["cmux vm workspace", "[--reuse]"], []),
            (["vm", "layout", "--help"], ["cmux vm layout"], ["cmux vm new"]),
            // The family text stays for the family itself and for verbs without their own usage.
            (["vm", "--help"], ["pause|resume", "terminal wait-exit", "exec [--timeout <s>]", "workspace new <machine> [--name <name>] [--reuse]"], ["resize"]),
            (["vm", "ls", "--help"], ["Usage: cmux vm <"], ["resize"]),
        ]
        for testCase in cases {
            let result = runProcess(executablePath: cliPath, arguments: testCase.arguments, environment: environment, timeout: 30)
            XCTAssertFalse(result.timedOut, "\(testCase.arguments) timed out")
            XCTAssertEqual(result.status, 0, "\(testCase.arguments): stdout=\(result.stdout) stderr=\(result.stderr)")
            for expected in testCase.expected {
                XCTAssertTrue(result.stdout.contains(expected), "\(testCase.arguments) should mention '\(expected)':\n\(result.stdout)")
            }
            for forbidden in testCase.forbidden {
                XCTAssertFalse(result.stdout.contains(forbidden), "\(testCase.arguments) must not mention '\(forbidden)':\n\(result.stdout)")
            }
        }
    }
}
