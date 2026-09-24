import CMUXAgentLaunch
import Foundation
import Testing

/// Exercises the bundled CLI with real provider files and a controlled app admission response.
@Suite(.serialized)
struct CMUXCLICodexUnavailableAdmissionTests {
    enum Scenario: CaseIterable, Sendable {
        case recovering, liveOwner, targetRemoved
        case olderApp, unadvertisedAdmission
        case missing, rejectedChild, bindingChanged
    }

    /// Unavailable provider evidence reaches admission before the saved invocation executes.
    @Test("Unreadable Codex evidence is handed to shared admission instead of returning busy")
    func unavailableEvidenceUsesAdmission() throws {
        try exerciseRestore(scenario: nil, explicitSurface: true)
    }

    /// Both CLI selectors preserve the admission and binding safety boundaries during recovery.
    @Test("Restore preserves recovery and rejection boundaries", arguments: Scenario.allCases, [false, true])
    func recoveryBoundaries(scenario: Scenario, explicitSurface: Bool) throws {
        try exerciseRestore(scenario: scenario, explicitSurface: explicitSurface)
    }

    /// Runs the actual CLI against isolated Codex state; nil selects immediate admission.
    private func exerciseRestore(scenario: Scenario?, explicitSurface: Bool) throws {
        let harness = CMUXCLIErrorOutputRegressionTests()
        let cliPath = try harness.bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-unavailable-admission-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("saved cwd", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let marker = codexHome.appendingPathComponent("restore-started")
        let executable = root.appendingPathComponent("codex")
        let checkpointID = UUID().uuidString.lowercased()
        let workspaceID = UUID().uuidString.lowercased()
        let surfaceID = UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        if scenario == .rejectedChild {
            let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let metadata: [String: Any] = ["type": "session_meta", "payload": [
                "id": checkpointID, "source": "exec", "originator": "codex_exec"
            ]]
            var data = try JSONSerialization.data(withJSONObject: metadata)
            data.append(0x0A)
            try data.write(to: sessions.appendingPathComponent("rollout-\(checkpointID).jsonl"))
        } else if scenario != .missing {
            try Data("not-a-sqlite-database".utf8)
                .write(to: codexHome.appendingPathComponent("state_5.sqlite"), options: .atomic)
            #expect(CodexSessionResumeVerifier().verify(
                sessionId: checkpointID, transcriptPath: nil, codexHome: codexHome.path
            ) == .unavailable, "The fixture must exercise unavailable evidence, not missing evidence")
        }
        try "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$CODEX_HOME\" \"$@\" >> \"$CODEX_HOME/restore-started\"\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let binding: [String: Any] = [
            "name": "Codex", "kind": "codex", "command": "codex resume \(checkpointID)",
            "cwd": workingDirectory.path,
            "checkpoint_id": scenario == .bindingChanged ? UUID().uuidString : checkpointID,
            "source": "agent-hook", "auto_resume": true, "updated_at": 123.5
        ]
        let record: [String: Any] = [
            "mode": "resumeAgent", "kind": "codex", "checkpoint_id": checkpointID,
            "source": "agent-hook", "working_directory": workingDirectory.path,
            "environment": ["CODEX_HOME": codexHome.path],
            "launch_command": [
                "launcher": "codex", "executable_path": executable.path,
                "arguments": [executable.path, "resume", checkpointID],
                "working_directory": workingDirectory.path,
                "environment": ["CODEX_HOME": codexHome.path]
            ],
            "prepared_arguments": [executable.path, "resume", checkpointID]
        ]
        var payload: [String: Any] = [
            "workspace_id": workspaceID, "surface_id": surfaceID,
            "restore_record": record, "resume_binding": binding
        ]
        if scenario != .unadvertisedAdmission {
            payload["agent_restore_admission_supported"] = scenario != .olderApp
        }
        let claimResponse = try jsonResponse(result: ["resume_claimed": true, "resume_binding": binding])
        let admissionResponse = try jsonResponse(result: ["admitted": true, "claim_id": UUID().uuidString])
        let recoveryResponse = try jsonResponse(result: ["admitted": false, "recovering": true])
        let ownerResponse = try jsonResponse(result: [
            "admitted": false, "recovering": true, "live_owner_pid": 4242
        ])
        let targetRemovedResponse = #"{"ok":false,"error":{"code":"not_found","message":"fixture target removed"}}"#
        var responses = [try jsonResponse(result: payload)]
        var expectedMethods = ["surface.resume.get"]
        switch scenario {
        case nil:
            responses += [admissionResponse, claimResponse]
            expectedMethods += ["agent.restore.admit", "surface.resume.get"]
        case .recovering:
            responses += [recoveryResponse, ownerResponse, admissionResponse, claimResponse]
            expectedMethods += ["agent.restore.admit", "agent.restore.admit", "agent.restore.admit", "surface.resume.get"]
        case .liveOwner, .targetRemoved:
            responses += [scenario == .liveOwner ? ownerResponse : recoveryResponse, targetRemovedResponse]
            expectedMethods += ["agent.restore.admit", "agent.restore.admit"]
        case .missing, .rejectedChild:
            responses += [try jsonResponse(result: ["cleared": true])]
            expectedMethods += ["surface.resume.clear"]
        case .olderApp, .unadvertisedAdmission, .bindingChanged:
            break
        }
        if !explicitSurface {
            responses.insert(try jsonResponse(result: [
                "caller": ["workspace_id": workspaceID, "surface_id": surfaceID], "focused": [:]
            ]), at: 0)
            expectedMethods.insert("system.identify", at: 0)
        }
        let socketPath = "/tmp/cmux-codex-unavailable-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, responses: responses)
        defer { responder.stop() }
        let result = harness.runProcess(
            executablePath: cliPath,
            arguments: ["restore"] + (explicitSurface ? ["--surface", surfaceID] : []) + ["codex", checkpointID],
            environment: [
                "HOME": root.path, "CFFIXED_USER_HOME": root.path,
                "CMUX_SOCKET_PATH": socketPath, "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_CLI_TTY_NAME": "ttys-restore-fixture", "PATH": "/usr/bin:/bin"
            ]
        )
        let requests = try responder.receivedRequests.map { request in
            try #require(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
        }
        let methods = requests.compactMap { $0["method"] as? String }
        let markerContents: String?
        do {
            markerContents = try String(contentsOf: marker, encoding: .utf8)
        } catch {
            markerContents = nil
        }
        let diagnostics = "\(result.diagnostics) methods=\(methods) marker=\(markerContents ?? "<missing>")"
        #expect(!result.timedOut, Comment(rawValue: diagnostics))
        #expect(methods == expectedMethods, Comment(rawValue: diagnostics))
        if scenario == nil || scenario == .recovering {
            #expect(result.status == 0, Comment(rawValue: diagnostics))
            let launched = (markerContents ?? "").split(separator: "\n").map(String.init)
            #expect(launched == [
                workingDirectory.resolvingSymlinksInPath().path,
                codexHome.path,
                "resume",
                checkpointID,
                "-c",
                "check_for_update_on_startup=false"
            ],
                    Comment(rawValue: diagnostics))
            #expect(result.stderr.isEmpty, Comment(rawValue: diagnostics))
            let claim = try #require(requests.last?["params"] as? [String: Any])
            #expect(claim["claim_checkpoint_id"] as? String == checkpointID)
            #expect(claim["claim_updated_at"] as? Double == 123.5)
        } else {
            #expect(result.status != 0, Comment(rawValue: diagnostics))
            #expect(markerContents == nil, "Rejected or unadmitted restores must not launch")
        }
        let admissions = requests.filter { $0["method"] as? String == "agent.restore.admit" }
        for (index, request) in admissions.enumerated() {
            let params = try #require(request["params"] as? [String: Any])
            #expect(params["session_id"] as? String == checkpointID)
            #expect(params["surface_id"] as? String == surfaceID)
            #expect((params["wait_for_change"] as? Bool ?? false) == (index > 0))
            #expect(params["codex_home"] as? String == codexHome.path)
        }
    }

    /// Encodes a successful v2 socket result for the CLI fixture.
    private func jsonResponse(result: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "result": result])
        return String(decoding: data, as: UTF8.self)
    }
}
