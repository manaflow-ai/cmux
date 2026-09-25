import CMUXAgentLaunch
import Darwin
import Foundation
import Testing

/// Executes the bundled CLI against a valid saved conversation and a real writer lock.
@Suite(.serialized)
struct CLICodexWriterLockRestoreTests {
    @Test("The final exec guard covers current and older apps, including legacy records", arguments: [false, true], [false, true])
    func heldWriterBlocksThenReleaseResumes(legacy: Bool, advertisesAdmission: Bool) throws {
        let runner = CMUXCLIErrorOutputRegressionTests()
        let cli = try runner.bundledCLIPath()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-12805-\(UUID().uuidString)")
        let capturedUser = root.appendingPathComponent("saved-user")
        let home = capturedUser.appendingPathComponent(".codex")
        let cwd = root.appendingPathComponent("project")
        let sessions = home.appendingPathComponent("sessions")
        let locks = home.appendingPathComponent("thread-writer-locks")
        let marker = home.appendingPathComponent("started")
        let executable = root.appendingPathComponent("codex")
        let session = UUID().uuidString.lowercased()
        let workspace = UUID().uuidString
        let surface = UUID().uuidString
        for directory in [cwd, sessions, locks] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata: [String: Any] = ["type": "session_meta", "payload": [
            "id": session, "cwd": cwd.path, "source": "cli", "originator": "codex-tui"
        ]]
        var rollout = try JSONSerialization.data(withJSONObject: metadata)
        rollout.append(10)
        try rollout.write(to: sessions.appendingPathComponent("rollout-\(session).jsonl"))
        guard case .exists = CodexSessionResumeVerifier().verify(
            sessionId: session, transcriptPath: nil, codexHome: home.path
        ) else {
            Issue.record("The fixture must be resumable before writer ownership is checked")
            return
        }
        try "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$CODEX_HOME\" \"$@\" > \"$CODEX_HOME/started\"\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        // Deliberately differs from the ambient HOME. Verification, admission,
        // the final lock check, and exec must all use this same saved account.
        var record: [String: Any] = [
            "kind": "codex", "mode": "resumeAgent", "checkpoint_id": session,
            "source": "session-snapshot", "working_directory": cwd.path
        ]
        if legacy {
            record["environment"] = ["CODEX_HOME": home.path]
            record["legacy_command"] = "'\(executable.path)' resume '\(session)'"
        } else {
            record["launch_command"] = [
                "launcher": "codex", "executable_path": executable.path,
                "arguments": [executable.path], "verification_home": capturedUser.path,
                "working_directory": cwd.path
            ]
        }
        var payload: [String: Any] = [
            "workspace_id": workspace, "surface_id": surface, "restore_record": record
        ]
        if advertisesAdmission { payload["agent_restore_admission_supported"] = true }
        let lockPath = locks.appendingPathComponent(session + ".lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        for held in [true, false] {
            if !held { try #require(flock(fd, LOCK_UN) == 0) }
            var responses = [try response(payload)]
            if advertisesAdmission {
                // Simulate a writer arriving after the app's preflight, too.
                responses += [try response(["admitted": true, "claim_id": UUID().uuidString])]
                if held { responses += [try response(["released": true])] }
            }
            let socket = "/tmp/cmux-writer-\(UUID().uuidString.prefix(8)).sock"
            let responder = try UnixSocketResponder(path: socket, responses: responses)
            defer { responder.stop() }
            let result = runner.runProcess(
                executablePath: cli, arguments: ["restore", "--surface", surface, "codex", session],
                environment: [
                    "HOME": root.path, "CFFIXED_USER_HOME": root.path, "PATH": "/usr/bin:/bin",
                    "CMUX_SOCKET_PATH": socket, "CMUX_CLI_SENTRY_DISABLED": "1", "SHELL": "/bin/sh"
                ],
                timeout: 20
            )
            try #require(!result.timedOut, Comment(rawValue: result.diagnostics))
            let requests = try responder.receivedRequests.map { request in
                try #require(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
            }
            let methods = requests.compactMap { $0["method"] as? String }
            #expect(methods == ["surface.resume.get"] + (advertisesAdmission
                ? ["agent.restore.admit"] + (held ? ["agent.restore.release"] : []) : []))
            if held {
                #expect(result.status != 0, Comment(rawValue: result.diagnostics))
                #expect(!FileManager.default.fileExists(atPath: marker.path))
                #expect(!result.stderr.contains(home.path))
                #expect(!result.stderr.contains(session))
                #expect(CodexWriterLockInspector().inspect(sessionID: session, codexHome: home.path).state == .active)
            } else {
                try #require(result.status == 0, Comment(rawValue: result.diagnostics))
                let started = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n").map(String.init)
                #expect(Array(started.prefix(2)) == [cwd.resolvingSymlinksInPath().path, home.path])
                #expect(started.contains(session))
                #expect(result.stderr.isEmpty, Comment(rawValue: result.diagnostics))
            }
        }
    }

    private func response(_ result: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), as: UTF8.self)
    }
}
