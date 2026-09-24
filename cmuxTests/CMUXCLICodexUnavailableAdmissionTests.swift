import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct CMUXCLICodexUnavailableAdmissionTests {
    @Test("Unreadable Codex evidence is handed to shared admission instead of returning busy")
    func unavailableEvidenceUsesAdmission() throws {
        let harness = CMUXCLIErrorOutputRegressionTests()
        let cliPath = try harness.bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-unavailable-admission-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("saved cwd", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let marker = root.appendingPathComponent("restore-started", isDirectory: false)
        let executable = root.appendingPathComponent("codex", isDirectory: false)
        let checkpointID = "01a03bc1-7649-7ec3-bdf7-03acf979e086"
        let workspaceID = UUID().uuidString.lowercased()
        let surfaceID = UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try Data("not-a-sqlite-database".utf8)
            .write(to: codexHome.appendingPathComponent("state_5.sqlite"), options: .atomic)
        try "#!/bin/sh\nprintf 'started\\n' > \"$RESTORE_MARKER\"\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let binding: [String: Any] = [
            "name": "Codex", "kind": "codex", "command": "codex resume \(checkpointID)",
            "cwd": workingDirectory.path, "checkpoint_id": checkpointID,
            "source": "agent-hook", "auto_resume": true, "updated_at": 123.5
        ]
        let record: [String: Any] = [
            "mode": "resumeAgent", "kind": "codex", "checkpoint_id": checkpointID,
            "source": "agent-hook", "working_directory": workingDirectory.path,
            "environment": ["CODEX_HOME": codexHome.path, "RESTORE_MARKER": marker.path],
            "launch_command": [
                "launcher": "codex", "executable_path": executable.path,
                "arguments": [executable.path, "resume", checkpointID],
                "working_directory": workingDirectory.path,
                "environment": ["CODEX_HOME": codexHome.path, "RESTORE_MARKER": marker.path]
            ],
            "prepared_arguments": [executable.path, "resume", checkpointID]
        ]
        let restorePayload = try jsonResponse(result: [
            "workspace_id": workspaceID, "surface_id": surfaceID,
            "agent_restore_admission_supported": true,
            "restore_record": record, "resume_binding": binding
        ])
        let claimResponse = try jsonResponse(result: [
            "resume_claimed": true, "resume_binding": binding
        ])
        let admissionResponse = try jsonResponse(result: [
            "admitted": true, "claim_id": UUID().uuidString
        ])
        let socketPath = "/tmp/cmux-codex-unavailable-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            responses: [restorePayload, admissionResponse, claimResponse]
        )
        defer { responder.stop() }
        let result = harness.runProcess(
            executablePath: cliPath,
            arguments: ["restore", "--surface", surfaceID, "codex", checkpointID],
            environment: [
                "HOME": root.path,
                "CFFIXED_USER_HOME": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "PATH": "/usr/bin:/bin"
            ],
            timeout: 10
        )

        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        let methods = try responder.receivedRequests.compactMap { request in
            (try? #require(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any]))?["method"] as? String
        }
        let markerContents = try? String(contentsOf: marker, encoding: .utf8)
        let diagnostics = "\(result.diagnostics) methods=\(methods) marker=\(markerContents ?? "<missing>")"
        #expect(result.status == 0, Comment(rawValue: diagnostics))
        #expect(markerContents == "started\n", Comment(rawValue: diagnostics))
        #expect(methods == ["surface.resume.get", "agent.restore.admit", "surface.resume.get"], Comment(rawValue: diagnostics))
        #expect(!result.stderr.localizedCaseInsensitiveContains("could not read its saved session records"), Comment(rawValue: diagnostics))
    }

    private func jsonResponse(result: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "result": result])
        return String(decoding: data, as: UTF8.self)
    }
}
