import Foundation
import Testing

@Suite(.serialized)
struct CLILegacyCodexRestoreLeaseTests {
    @Test("Legacy execution preserves mode and protects resumed conversations", arguments: [
        ("codex", "resumeAgent", false, true), ("codex", "resumeAgent", true, true),
        ("codex", "direct", false, false), ("codex", "relaunchAgent", false, false),
        ("custom-agent", "legacy-mode", false, false)
    ])
    func legacyLaunchHoldsLease(kind: String, mode: String, plannerFallback: Bool, expectsLease: Bool) throws {
        let runner = CMUXCLIErrorOutputRegressionTests()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-legacy-lease-\(UUID().uuidString)")
        let home = root.appendingPathComponent("account")
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID().uuidString.lowercased()
        let rollout = try JSONSerialization.data(withJSONObject: [
            "type": "session_meta", "payload": ["id": session, "cwd": root.path, "source": "cli", "originator": "codex-tui"]
        ])
        try rollout.write(to: sessions.appendingPathComponent("rollout-\(session).jsonl"))
        let executable = root.appendingPathComponent("codex")
        let probe = """
        #!/usr/bin/python3
        import fcntl, json, os, pathlib, sys
        held = False
        for path in pathlib.Path(os.environ['HOME'], '.cmuxterm', 'agent-restore-launches').glob('*.lock'):
            with path.open() as lock:
                try:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    held = True
        print(json.dumps(dict(held=held, home=os.environ['CODEX_HOME'], cwd=os.getcwd(), argv=sys.argv[1:])))
        """
        try probe.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var record: [String: Any] = [
            "kind": kind, "mode": mode, "checkpoint_id": session,
            "source": "session-snapshot", "working_directory": root.path,
            "environment": ["CODEX_HOME": home.path],
            "legacy_command": "'\(executable.path)' resume '\(session)' --model 'legacy model'"
        ]
        if plannerFallback {
            // A captured management command cannot be resumed. The legacy
            // conversation command is the only valid continuation in this record.
            record["launch_command"] = [
                "launcher": "codexTeams", "executable_path": "cmux",
                "arguments": ["cmux", "codex-teams", "login"]
            ]
        }
        let payload = try JSONSerialization.data(withJSONObject: [
            "ok": true, "result": ["restore_record": record]
        ])
        let socket = "/tmp/cmux-legacy-lease-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socket, response: String(decoding: payload, as: UTF8.self))
        defer { responder.stop() }
        let result = runner.runProcess(
            executablePath: try runner.bundledCLIPath(),
            arguments: ["restore", "--surface", UUID().uuidString, kind, session],
            environment: [
                "HOME": root.path, "CFFIXED_USER_HOME": root.path, "PATH": "/usr/bin:/bin",
                "CMUX_SOCKET_PATH": socket, "CMUX_CLI_SENTRY_DISABLED": "1", "SHELL": "/bin/sh"
            ],
            timeout: 15
        )
        try #require(!result.timedOut && result.status == 0, Comment(rawValue: result.diagnostics))
        let value = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(value["held"] as? Bool == expectsLease, Comment(rawValue: result.diagnostics))
        #expect(value["home"] as? String == home.path)
        #expect((value["argv"] as? [String])?.contains("legacy model") == true)
    }
}
