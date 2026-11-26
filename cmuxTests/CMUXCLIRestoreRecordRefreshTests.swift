import CMUXAgentLaunch
import Foundation
import Testing

/// Runs the bundled CLI the way session restore does for every terminal in a
/// relaunched window: one `cmux restore` per surface, each waiting on admission.
///
/// While the background surfaces wait, the app's autosave pass can refresh their
/// restore records from the hook store (same session, newer launch details). The
/// app then answers admission with `conflict`. That must re-plan the launch from
/// the current record, not leave the terminal idle.
@Suite(.serialized)
struct CMUXCLIRestoreRecordRefreshTests {
    /// How the surface's record behaves between the CLI's first read and admission.
    enum RecordChange: Sendable {
        /// The focused workspace: admitted on the first try.
        case unchanged
        /// A background workspace: same session, launch details refreshed.
        case refreshedSameSession
        /// The surface now names a different session: never launch either one.
        case differentSession
    }

    @Test("Every workspace's agent restores when background records refresh during admission")
    func threeWorkspacesOnlyFirstFocused() throws {
        let outcomes = try [RecordChange.unchanged, .refreshedSameSession, .refreshedSameSession]
            .map(exerciseRestore)
        #expect(outcomes == [true, true, true])
    }

    @Test("A record that now names another session still refuses to launch")
    func differentSessionStillRefuses() throws {
        #expect(try exerciseRestore(.differentSession) == false)
    }

    /// Runs one surface's `cmux restore --surface <id> codex <session>`; true when the agent launched.
    private func exerciseRestore(_ change: RecordChange) throws -> Bool {
        let harness = CMUXCLIErrorOutputRegressionTests()
        let cliPath = try harness.bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restore-record-refresh-\(UUID().uuidString)", isDirectory: true)
        let savedDirectory = root.appendingPathComponent("saved cwd", isDirectory: true)
        let refreshedDirectory = root.appendingPathComponent("refreshed cwd", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let marker = codexHome.appendingPathComponent("restore-started")
        let executable = root.appendingPathComponent("codex")
        let checkpointID = UUID().uuidString.lowercased()
        let workspaceID = UUID().uuidString.lowercased()
        let surfaceID = UUID().uuidString.lowercased()
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [savedDirectory, refreshedDirectory, codexHome] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Unreadable provider state sends the restore through app admission.
        try Data("not-a-sqlite-database".utf8)
            .write(to: codexHome.appendingPathComponent("state_5.sqlite"), options: .atomic)
        try "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$@\" >> \"$CODEX_HOME/restore-started\"\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        func payload(sessionID: String, workingDirectory: URL) throws -> String {
            let binding: [String: Any] = [
                "name": "Codex", "kind": "codex", "command": "codex resume \(sessionID)",
                "cwd": workingDirectory.path, "checkpoint_id": sessionID,
                "source": "agent-hook", "auto_resume": true, "updated_at": 123.5
            ]
            let record: [String: Any] = [
                "mode": "resumeAgent", "kind": "codex", "checkpoint_id": sessionID,
                "source": "agent-hook", "working_directory": workingDirectory.path,
                "environment": ["CODEX_HOME": codexHome.path],
                "launch_command": [
                    "launcher": "codex", "executable_path": executable.path,
                    "arguments": [executable.path, "resume", sessionID],
                    "working_directory": workingDirectory.path,
                    "environment": ["CODEX_HOME": codexHome.path]
                ],
                "prepared_arguments": [executable.path, "resume", sessionID]
            ]
            return try jsonResponse(result: [
                "workspace_id": workspaceID, "surface_id": surfaceID,
                "restore_record": record, "resume_binding": binding,
                "agent_restore_admission_supported": true
            ])
        }
        let saved = try payload(sessionID: checkpointID, workingDirectory: savedDirectory)
        let refreshed = try payload(sessionID: checkpointID, workingDirectory: refreshedDirectory)
        let replaced = try payload(sessionID: UUID().uuidString.lowercased(), workingDirectory: savedDirectory)
        let admitted = try jsonResponse(result: ["admitted": true, "claim_id": UUID().uuidString])
        let claimed = try jsonResponse(result: ["resume_claimed": true])
        let conflict = #"{"ok":false,"error":{"code":"conflict","message":"The surface restore record changed. Run 'cmux restore --surface' again."}}"#

        let responses: [String]
        let expectedDirectory: URL
        switch change {
        case .unchanged:
            responses = [saved, admitted, claimed]
            expectedDirectory = savedDirectory
        case .refreshedSameSession:
            // First plan → conflict → CLI reads the refreshed record → plans again → admitted.
            responses = [saved, conflict, refreshed, refreshed, admitted, claimed]
            expectedDirectory = refreshedDirectory
        case .differentSession:
            responses = [saved, conflict, replaced]
            expectedDirectory = savedDirectory
        }
        let socketPath = "/tmp/cmux-restore-refresh-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, responses: responses)
        defer { responder.stop() }
        let result = harness.runProcess(
            executablePath: cliPath,
            arguments: ["restore", "--surface", surfaceID, "codex", checkpointID],
            environment: [
                "HOME": root.path, "CFFIXED_USER_HOME": root.path,
                "CMUX_SOCKET_PATH": socketPath, "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CLI_TTY_NAME": "ttys-restore-refresh", "PATH": "/usr/bin:/bin"
            ]
        )
        let methods = try responder.receivedRequests.compactMap { request in
            try #require(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])["method"] as? String
        }
        let launched = (try? String(contentsOf: marker, encoding: .utf8))?
            .split(separator: "\n").map(String.init)
        let diagnostics = Comment(rawValue: "\(change) \(result.diagnostics) methods=\(methods) launched=\(launched ?? [])")
        #expect(!result.timedOut, diagnostics)
        guard result.status == 0 else {
            #expect(launched == nil, "A refused restore must not launch the agent")
            return false
        }
        #expect(launched?.first == expectedDirectory.resolvingSymlinksInPath().path, diagnostics)
        #expect(launched?.dropFirst().prefix(2) == ["resume", checkpointID][...], diagnostics)
        return launched != nil
    }

    private func jsonResponse(result: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "result": result])
        return String(decoding: data, as: UTF8.self)
    }
}
