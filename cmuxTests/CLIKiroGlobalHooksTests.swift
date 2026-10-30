import XCTest
import Darwin

/// `cmux hooks setup kiro --global` writes the Kiro CLI V3 global hooks file
/// (`$KIRO_HOME/hooks/cmux.json`, default `~/.kiro/hooks/cmux.json`). Kiro V3
/// runs it for every agent, so it carries only lifecycle and agent-message
/// events, never blocks, and writes to the model context only to deliver a
/// waiting message. https://kiro.dev/docs/hooks/
extension CLINotifyProcessIntegrationRegressionTests {
    private struct KiroGlobalHookSandbox {
        let root: URL
        var home: URL { root.appendingPathComponent("home", isDirectory: true) }
        var defaultHooksFile: URL {
            home.appendingPathComponent(".kiro/hooks/cmux.json", isDirectory: false)
        }
        var defaultAgentFile: URL {
            home.appendingPathComponent(".kiro/agents/cmux.json", isDirectory: false)
        }

        func environment(_ extra: [String: String] = [:]) -> [String: String] {
            [
                "HOME": home.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ].merging(extra) { _, new in new }
        }
    }

    private func makeKiroGlobalHookSandbox() throws -> KiroGlobalHookSandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-kiro-global-\(UUID().uuidString)", isDirectory: true)
        let sandbox = KiroGlobalHookSandbox(root: root)
        try FileManager.default.createDirectory(at: sandbox.home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return sandbox
    }

    private func runKiroHooksCLI(
        _ arguments: [String],
        environment: [String: String]
    ) throws -> ProcessRunResult {
        let result = runProcess(
            executablePath: try bundledCLIPath(),
            arguments: arguments,
            environment: environment,
            timeout: 5
        )
        XCTAssertFalse(result.timedOut, result.stderr)
        return result
    }

    private func kiroGlobalHookEntries(at url: URL) throws -> [[String: Any]] {
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(json["version"] as? String, "v1")
        return try XCTUnwrap(json["hooks"] as? [[String: Any]])
    }

    private func kiroGlobalHookCommand(_ entry: [String: Any]) -> String {
        (entry["action"] as? [String: Any])?["command"] as? String ?? ""
    }

    private func writeExecutable(_ body: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func testKiroGlobalHookInstallWritesV3LifecycleAndMessageHooks() throws {
        let sandbox = try makeKiroGlobalHookSandbox()
        let result = try runKiroHooksCLI(
            ["hooks", "kiro", "install", "--global", "--yes"],
            environment: sandbox.environment()
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("V3"), "Expected the V3-only note, saw: \(result.stdout)")

        let entries = try kiroGlobalHookEntries(at: sandbox.defaultHooksFile)
        XCTAssertEqual(
            entries.map { $0["trigger"] as? String },
            ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd", "UserPromptSubmit", "Stop"]
        )
        for entry in entries {
            let command = kiroGlobalHookCommand(entry)
            // V3 timeouts are seconds, unlike the agent config's timeout_ms.
            XCTAssertEqual(entry["timeout"] as? Int, 5)
            XCTAssertNil(entry["timeout_ms"])
            XCTAssertEqual(entry["enabled"] as? Bool, true)
            XCTAssertEqual((entry["action"] as? [String: Any])?["type"] as? String, "command")
            XCTAssertFalse(command.contains("hooks feed"), "Feed bridge must stay on --agent cmux: \(command)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sandbox.defaultAgentFile.path),
            "--global must not write the cmux agent config"
        )
    }

    func testKiroGlobalHookSetupHonorsKiroHome() throws {
        let sandbox = try makeKiroGlobalHookSandbox()
        let kiroHome = sandbox.root.appendingPathComponent("kiro home", isDirectory: true)
        let bin = sandbox.root.appendingPathComponent("bin", isDirectory: true)
        try writeExecutable("#!/bin/sh\nexit 0\n", to: bin.appendingPathComponent("kiro-cli", isDirectory: false))

        let result = try runKiroHooksCLI(
            ["hooks", "setup", "kiro", "--global", "--yes"],
            environment: sandbox.environment([
                "KIRO_HOME": kiroHome.path,
                "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            ])
        )
        XCTAssertEqual(result.status, 0, result.stderr)

        let hooksFile = kiroHome.appendingPathComponent("hooks/cmux.json", isDirectory: false)
        XCTAssertEqual(try kiroGlobalHookEntries(at: hooksFile).count, 6)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.defaultHooksFile.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: kiroHome.appendingPathComponent("agents/cmux.json").path),
            "setup --global must not also run the default agent-config install"
        )
    }

    func testKiroGlobalHookInstallIsIdempotent() throws {
        let sandbox = try makeKiroGlobalHookSandbox()
        let first = try runKiroHooksCLI(
            ["hooks", "kiro", "install", "--global", "--yes"],
            environment: sandbox.environment()
        )
        XCTAssertEqual(first.status, 0, first.stderr)
        let firstBytes = try Data(contentsOf: sandbox.defaultHooksFile)

        let second = try runKiroHooksCLI(
            ["hooks", "kiro", "install", "--global", "--yes"],
            environment: sandbox.environment()
        )
        XCTAssertEqual(second.status, 0, second.stderr)
        XCTAssertTrue(second.stdout.contains("already up to date"), second.stdout)
        XCTAssertEqual(try Data(contentsOf: sandbox.defaultHooksFile), firstBytes)
        XCTAssertEqual(try kiroGlobalHookEntries(at: sandbox.defaultHooksFile).count, 6)
    }

    func testKiroGlobalHookUninstallRemovesOnlyCmuxEntriesAndFiles() throws {
        let sandbox = try makeKiroGlobalHookSandbox()
        let env = sandbox.environment()
        let hooksDir = sandbox.defaultHooksFile.deletingLastPathComponent()
        XCTAssertEqual(try runKiroHooksCLI(["hooks", "kiro", "install", "--global", "--yes"], environment: env).status, 0)
        let otherFile = hooksDir.appendingPathComponent("other.json", isDirectory: false)
        let otherContent = #"{"version":"v1","hooks":[{"name":"mine","trigger":"Stop","action":{"type":"command","command":"true"}}]}"#
        try otherContent.write(to: otherFile, atomically: true, encoding: .utf8)

        // A user entry appended to cmux's file survives reinstall and uninstall.
        var entries = try kiroGlobalHookEntries(at: sandbox.defaultHooksFile)
        entries.append(["name": "user-hook", "trigger": "Stop", "action": ["type": "command", "command": "true"]])
        try JSONSerialization.data(withJSONObject: ["version": "v1", "hooks": entries])
            .write(to: sandbox.defaultHooksFile)
        XCTAssertEqual(try runKiroHooksCLI(["hooks", "kiro", "install", "--global", "--yes"], environment: env).status, 0)
        XCTAssertEqual(try kiroGlobalHookEntries(at: sandbox.defaultHooksFile).count, 7)

        let partial = try runKiroHooksCLI(["hooks", "uninstall", "kiro", "--global"], environment: env)
        XCTAssertEqual(partial.status, 0, partial.stderr)
        let afterPartial = try kiroGlobalHookEntries(at: sandbox.defaultHooksFile)
        XCTAssertEqual(afterPartial.map { $0["name"] as? String }, ["user-hook", "cmux-ownership"])
        let ownership = try XCTUnwrap(afterPartial.last)
        XCTAssertEqual(ownership["enabled"] as? Bool, false, "the ownership marker must never run")

        // The marker lets a later install adopt the file again, keeping the user entry.
        let reinstall = try runKiroHooksCLI(["hooks", "kiro", "install", "--global", "--yes"], environment: env)
        XCTAssertEqual(reinstall.status, 0, reinstall.stderr)
        let afterReinstall = try kiroGlobalHookEntries(at: sandbox.defaultHooksFile).map { $0["name"] as? String }
        XCTAssertEqual(afterReinstall.count, 7)
        XCTAssertTrue(afterReinstall.contains("user-hook"))
        XCTAssertFalse(afterReinstall.contains("cmux-ownership"))

        // With only cmux's entries in it, uninstall deletes cmux's file and
        // nothing else in the directory.
        try FileManager.default.removeItem(at: sandbox.defaultHooksFile)
        XCTAssertEqual(try runKiroHooksCLI(["hooks", "kiro", "install", "--global", "--yes"], environment: env).status, 0)
        let full = try runKiroHooksCLI(["hooks", "kiro", "uninstall", "--global"], environment: env)
        XCTAssertEqual(full.status, 0, full.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.defaultHooksFile.path))
        XCTAssertEqual(try String(contentsOf: otherFile, encoding: .utf8), otherContent)
    }

    func testKiroGlobalHookInstallRefusesForeignCmuxJSON() throws {
        let sandbox = try makeKiroGlobalHookSandbox()
        let env = sandbox.environment()
        try FileManager.default.createDirectory(
            at: sandbox.defaultHooksFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let foreign = #"{"version":"v1","hooks":[{"name":"theirs","trigger":"Stop","action":{"type":"command","command":"true"}}]}"#
        try foreign.write(to: sandbox.defaultHooksFile, atomically: true, encoding: .utf8)

        // Files with no cmux entry, whatever shape their `hooks` value has,
        // are someone else's: install refuses and uninstall leaves them.
        for content in [
            foreign,
            #"{"version":"v1","hooks":{"Stop":[]}}"#,
            #"{"version":"v1","hooks":[],"owner":"someone-else"}"#,
        ] {
            try content.write(to: sandbox.defaultHooksFile, atomically: true, encoding: .utf8)
            let install = try runKiroHooksCLI(["hooks", "kiro", "install", "--global", "--yes"], environment: env)
            XCTAssertNotEqual(install.status, 0, content)
            let uninstall = try runKiroHooksCLI(["hooks", "kiro", "uninstall", "--global"], environment: env)
            XCTAssertEqual(uninstall.status, 0, uninstall.stderr)
            XCTAssertEqual(try String(contentsOf: sandbox.defaultHooksFile, encoding: .utf8), content)
        }
    }

    func testKiroGlobalHookCommandSuppressesOutputAndFailsOpen() throws {
        let sandbox = try makeKiroGlobalHookSandbox()
        XCTAssertEqual(
            try runKiroHooksCLI(["hooks", "kiro", "install", "--global", "--yes"], environment: sandbox.environment()).status,
            0
        )
        let entries = try kiroGlobalHookEntries(at: sandbox.defaultHooksFile)
        let sessionStart = kiroGlobalHookCommand(
            try XCTUnwrap(entries.first { $0["trigger"] as? String == "SessionStart" })
        )

        // A cmux that prints and exits 2 stands in for anything V3 would read
        // as model context or a block decision.
        let bin = sandbox.root.appendingPathComponent("fake-cmux-bin", isDirectory: true)
        let log = sandbox.root.appendingPathComponent("fake-cmux.log", isDirectory: false)
        try writeExecutable(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$CMUX_FAKE_LOG\"\necho INJECTED\necho FAILED >&2\nexit 2\n",
            to: bin.appendingPathComponent("cmux", isDirectory: false)
        )

        func runHook(_ environment: [String: String]) -> ProcessRunResult {
            runProcess(
                executablePath: "/bin/sh",
                arguments: ["-c", sessionStart],
                environment: ["CMUX_FAKE_LOG": log.path].merging(environment) { _, new in new },
                standardInput: #"{"hook_event_name":"SessionStart","session_id":"kiro-v3"}"#,
                timeout: 5
            )
        }
        func logLines() -> [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        let withFakeCmux = "\(bin.path):/usr/bin:/bin"

        let outside = runHook(["PATH": withFakeCmux])
        XCTAssertEqual(outside.status, 0)
        XCTAssertEqual(outside.stdout, "")
        XCTAssertEqual(logLines(), [], "Outside cmux (no CMUX_SURFACE_ID) the hook must not dispatch")

        let disabled = runHook(["PATH": withFakeCmux, "CMUX_SURFACE_ID": "surface", "CMUX_KIRO_HOOKS_DISABLED": "1"])
        XCTAssertEqual(disabled.status, 0)
        XCTAssertEqual(disabled.stdout, "")
        XCTAssertEqual(logLines(), [])

        let noCmux = runHook(["PATH": "/usr/bin:/bin", "CMUX_SURFACE_ID": "surface"])
        XCTAssertEqual(noCmux.status, 0)
        XCTAssertEqual(noCmux.stdout, "")

        let inside = runHook(["PATH": withFakeCmux, "CMUX_SURFACE_ID": "surface"])
        XCTAssertEqual(inside.status, 0, "A failing cmux must not block Kiro")
        XCTAssertEqual(inside.stdout, "", "Hook stdout would be added to the V3 model context")
        XCTAssertEqual(inside.stderr, "")
        XCTAssertEqual(logLines(), ["hooks enqueue kiro session-start"])
    }

    func testKiroGlobalMessageHookPassesOnlyAWaitingMessage() throws {
        let sandbox = try makeKiroGlobalHookSandbox()
        XCTAssertEqual(
            try runKiroHooksCLI(["hooks", "kiro", "install", "--global", "--yes"], environment: sandbox.environment()).status,
            0
        )
        let entries = try kiroGlobalHookEntries(at: sandbox.defaultHooksFile)
        let drain = kiroGlobalHookCommand(
            try XCTUnwrap(entries.first { $0["name"] as? String == "cmux-inbox-drain" })
        )
        let bin = sandbox.root.appendingPathComponent("fake-cmux-bin", isDirectory: true)
        let log = sandbox.root.appendingPathComponent("fake-cmux.log", isDirectory: false)

        func runHook(cmuxOutput: String, _ environment: [String: String]) throws -> ProcessRunResult {
            try writeExecutable(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$CMUX_FAKE_LOG\"\nprintf '%s' '\(cmuxOutput)'\n",
                to: bin.appendingPathComponent("cmux", isDirectory: false)
            )
            return runProcess(
                executablePath: "/bin/sh",
                arguments: ["-c", drain],
                environment: ["CMUX_FAKE_LOG": log.path, "PATH": "\(bin.path):/usr/bin:/bin"]
                    .merging(environment) { _, new in new },
                standardInput: #"{"hook_event_name":"UserPromptSubmit","session_id":"kiro-v3"}"#,
                timeout: 5
            )
        }

        let message = try runHook(cmuxOutput: "[cmux agent message] from a", ["CMUX_SURFACE_ID": "surface"])
        XCTAssertEqual(message.status, 0)
        XCTAssertEqual(message.stdout, "[cmux agent message] from a\n")

        // An older cmux answers `{}`; Kiro would add it to the model context.
        let olderCmux = try runHook(cmuxOutput: "{}", ["CMUX_SURFACE_ID": "surface"])
        XCTAssertEqual(olderCmux.status, 0)
        XCTAssertEqual(olderCmux.stdout, "")

        let outside = try runHook(cmuxOutput: "leak", [:])
        XCTAssertEqual(outside.status, 0)
        XCTAssertEqual(outside.stdout, "")

        let disabled = try runHook(cmuxOutput: "leak", ["CMUX_SURFACE_ID": "surface", "CMUX_KIRO_HOOKS_DISABLED": "1"])
        XCTAssertEqual(disabled.status, 0)
        XCTAssertEqual(disabled.stdout, "")

        let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["hooks kiro inbox-drain", "hooks kiro inbox-drain"])
    }

    func testKiroDefaultInstallUnchangedAndWarnsWhenBothInstalled() throws {
        let sandbox = try makeKiroGlobalHookSandbox()
        let env = sandbox.environment()
        let defaultInstall = try runKiroHooksCLI(["hooks", "kiro", "install", "--yes"], environment: env)
        XCTAssertEqual(defaultInstall.status, 0, defaultInstall.stderr)
        XCTAssertTrue(defaultInstall.stdout.contains("kiro-cli chat --agent cmux"), defaultInstall.stdout)
        XCTAssertFalse(defaultInstall.stdout.contains("twice"), defaultInstall.stdout)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.defaultAgentFile.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sandbox.defaultHooksFile.deletingLastPathComponent().path),
            "The default install must not create the V3 global hooks directory"
        )

        let global = try runKiroHooksCLI(["hooks", "kiro", "install", "--global", "--yes"], environment: env)
        XCTAssertEqual(global.status, 0, global.stderr)
        XCTAssertTrue(global.stdout.contains("twice"), "Expected the double-fire note, saw: \(global.stdout)")

        let reinstall = try runKiroHooksCLI(["hooks", "kiro", "install", "--yes"], environment: env)
        XCTAssertEqual(reinstall.status, 0, reinstall.stderr)
        XCTAssertTrue(reinstall.stdout.contains("twice"), reinstall.stdout)

        // Removing the global file leaves the agent config alone.
        let agentBytes = try Data(contentsOf: sandbox.defaultAgentFile)
        XCTAssertEqual(try runKiroHooksCLI(["hooks", "kiro", "uninstall", "--global"], environment: env).status, 0)
        XCTAssertEqual(try Data(contentsOf: sandbox.defaultAgentFile), agentBytes)
    }

    func testGlobalFlagIsRejectedForOtherAgents() throws {
        let sandbox = try makeKiroGlobalHookSandbox()
        let env = sandbox.environment()
        let codex = try runKiroHooksCLI(["hooks", "codex", "install", "--global", "--yes"], environment: env)
        XCTAssertNotEqual(codex.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.home.appendingPathComponent(".codex").path))

        let everyAgent = try runKiroHooksCLI(["hooks", "setup", "--global", "--yes"], environment: env)
        XCTAssertNotEqual(everyAgent.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.home.appendingPathComponent(".kiro").path))
    }

    func testKiroHookRecordsTheKiroCLIProcessAboveANonShellHookParent() throws {
        // Kiro CLI V3 runs hook commands under a process that is neither a
        // shell wrapper nor `kiro-cli`. The hook must still record the
        // `kiro-cli` process, or restore rejects the launch capture.
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("hook-kiro-parent")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-kiro-parent-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "kiro-parent-session-123"

        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
        // A compiled `kiro-cli` that runs its argument through system(3)
        // stands in for the agent, so the kernel names the process
        // `kiro-cli`. A link to bash stands in for the non-shell process that
        // runs its hooks (`node`).
        let kiroCLI = bin.appendingPathComponent("kiro-cli", isDirectory: false)
        let kiroCLISource = bin.appendingPathComponent("kiro-cli.c", isDirectory: false)
        try "#include <stdlib.h>\nint main(int argc, char **argv) { return argc > 1 ? system(argv[1]) >> 8 : 2; }\n"
            .write(to: kiroCLISource, atomically: true, encoding: .utf8)
        let compile = runProcess(
            executablePath: "/usr/bin/cc",
            arguments: ["-o", kiroCLI.path, kiroCLISource.path],
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 60
        )
        XCTAssertEqual(compile.status, 0, compile.stderr)
        let hookRunner = bin.appendingPathComponent("node", isDirectory: false)
        try FileManager.default.createSymbolicLink(atPath: hookRunner.path, withDestinationPath: "/bin/bash")
        let pidFile = root.appendingPathComponent("kiro-cli.pid", isDirectory: false)
        let inputFile = root.appendingPathComponent("hook-input.json", isDirectory: false)
        try #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"SessionStart"}"#
            .write(to: inputFile, atomically: true, encoding: .utf8)

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return "OK"
            }
            switch method {
            case "agent.resolve_delivery_target":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: ["workspace_id": workspaceId, "surface_id": surfaceId, "source": "pid"]
                )
            case "surface.list":
                return self.surfaceListResponse(id: id, surfaceId: surfaceId)
            case "surface.resume.set":
                return self.v2Response(id: id, ok: true, result: ["ok": true])
            case "feed.push":
                return self.v2Response(id: id, ok: true, result: [:])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": method])
            }
        }

        // Each shell runs a command after its child, so it stays in the chain
        // instead of exec-replacing itself, and still exits with the hook's status.
        let result = runProcess(
            executablePath: kiroCLI.path,
            arguments: [
                #"echo $PPID > "$PID_FILE"; "$HOOK_RUNNER" -c '"$CMUX_CLI" hooks kiro session-start < "$HOOK_INPUT"; status=$?; exit $status'; status=$?; exit $status"#,
            ],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PWD": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId,
                "CMUX_AGENT_HOOK_STATE_DIR": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CLI": cliPath,
                "HOOK_RUNNER": hookRunner.path,
                "HOOK_INPUT": inputFile.path,
                "PID_FILE": pidFile.path,
            ],
            timeout: 10
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let kiroCLIPID = try XCTUnwrap(
            Int(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        )

        let storeURL = root.appendingPathComponent("kiro-hook-sessions.json", isDirectory: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        let session = try XCTUnwrap((json["sessions"] as? [String: Any])?[sessionId] as? [String: Any])
        XCTAssertEqual((session["pid"] as? NSNumber)?.intValue, kiroCLIPID, "\(session)")
        let launchCommand = try XCTUnwrap(session["launchCommand"] as? [String: Any])
        XCTAssertNotEqual(
            launchCommand["rejectionReason"] as? String,
            "nativeProcessDoesNotDescribeKind",
            "the launch capture must come from kiro-cli, not the hook runner: \(launchCommand)"
        )
    }
}
