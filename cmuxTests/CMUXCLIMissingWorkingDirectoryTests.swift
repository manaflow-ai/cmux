import Foundation
import SQLite3
import Testing

@Suite(.serialized)
struct CMUXCLIMissingWorkingDirectoryTests {
    @Test(arguments: ["restore", "fork"], [false, true])
    func refusesUnusableSavedDirectory(verb: String, pathIsFile: Bool) throws {
        let fixture = try Fixture(pathIsFile: pathIsFile)
        defer { fixture.remove() }
        var record = fixture.record(kind: "custom-agent")
        record["launch_command"] = [
            "arguments": [fixture.executable.path],
            "executable_path": fixture.executable.path,
            "working_directory": fixture.savedDirectory.path,
        ]
        record["prepared_arguments"] = [fixture.executable.path, "--resume", fixture.checkpoint]
        record["prepared_fork_arguments"] = [fixture.executable.path, "--fork", fixture.checkpoint]
        let result = try fixture.run(verb: verb, record: record)
        fixture.expectRefusal(result.process, verb: verb)
        #expect(result.methods == ["surface.resume.get"])
    }

    @Test(arguments: ["restore", "fork"])
    func keepsMissingCodexBindingWhileDirectoryIsGone(verb: String) throws {
        let fixture = try Fixture(pathIsFile: false)
        defer { fixture.remove() }
        var database: OpaquePointer?
        let status = sqlite3_open(fixture.codexHome.appendingPathComponent("state_5.sqlite").path, &database)
        defer { sqlite3_close(database) }
        try #require(status == SQLITE_OK)
        let schema = "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, source TEXT, thread_source TEXT)"
        try #require(sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK)
        var record = fixture.record(kind: "codex")
        record["prepared_arguments"] = [fixture.executable.path, "resume", fixture.checkpoint]
        record["prepared_fork_arguments"] = [fixture.executable.path, "fork", fixture.checkpoint]
        let result = try fixture.run(verb: verb, record: record)
        fixture.expectRefusal(result.process, verb: verb)
        #expect(result.methods == ["surface.resume.get"])
    }

    @Test(arguments: ["missing", "file", "directory"], [false, true])
    func legacyCodexForkChecksDirectoryBeforeClearingBinding(pathKind: String, plannerFallback: Bool) throws {
        let fixture = try Fixture(pathIsFile: pathKind == "file")
        defer { fixture.remove() }
        if pathKind == "directory" {
            try FileManager.default.createDirectory(at: fixture.savedDirectory, withIntermediateDirectories: true)
        }
        let sessions = fixture.codexHome.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = try JSONSerialization.data(withJSONObject: [
            "type": "session_meta", "payload": [
                "id": fixture.checkpoint, "cwd": fixture.savedDirectory.path,
                "source": "cli", "originator": "codex-tui",
            ],
        ])
        try rollout.write(to: sessions.appendingPathComponent("rollout-\(fixture.checkpoint).jsonl"))
        var record = fixture.record(kind: "codex")
        record["legacy_command"] = "'\(fixture.executable.path)' --fork '\(fixture.checkpoint)'"
        if plannerFallback {
            // A management command cannot supply structured continuation argv.
            record["launch_command"] = [
                "launcher": "codexTeams", "executable_path": "cmux",
                "arguments": ["cmux", "codex-teams", "login"],
            ]
        }
        let result = try fixture.run(verb: "fork", record: record)
        if pathKind == "directory" {
            #expect(!result.process.timedOut && result.process.status == 0,
                    Comment(rawValue: result.process.diagnostics))
            #expect(result.methods == ["surface.resume.get", "surface.resume.clear"])
            let output = try String(contentsOf: fixture.marker, encoding: .utf8)
            #expect(URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines))
                .resolvingSymlinksInPath().path == fixture.savedDirectory.resolvingSymlinksInPath().path)
        } else {
            fixture.expectRefusal(result.process, verb: "fork")
            #expect(result.methods == ["surface.resume.get"])
        }
    }

    private struct Fixture {
        let root: URL
        let savedDirectory: URL
        let executable: URL
        let marker: URL
        let codexHome: URL
        let checkpoint = UUID().uuidString.lowercased()

        init(pathIsFile: Bool) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux missing cwd \(UUID().uuidString)")
            savedDirectory = root.appendingPathComponent("saved directory")
            executable = root.appendingPathComponent("codex")
            marker = root.appendingPathComponent("launched")
            codexHome = root.appendingPathComponent(".codex")
            try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
            if pathIsFile {
                try Data("file".utf8).write(to: savedDirectory)
            }
            try """
            #!/bin/sh
            printf '%s\\n' "$PWD" > "$CWD_TEST_LAUNCH_MARKER"
            """.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        func record(kind: String) -> [String: Any] {
            [
                "mode": "resumeAgent", "kind": kind, "checkpoint_id": checkpoint,
                "source": "session-snapshot", "working_directory": savedDirectory.path,
                "environment": ["CODEX_HOME": codexHome.path],
            ]
        }

        func run(verb: String, record: [String: Any]) throws -> (
            process: CMUXCLIErrorOutputRegressionTests.ProcessRunResult, methods: [String]
        ) {
            let surface = UUID().uuidString.lowercased()
            let workspace = UUID().uuidString.lowercased()
            let response = try JSONSerialization.data(withJSONObject: [
                "ok": true, "result": [
                    "workspace_id": workspace, "surface_id": surface,
                    "caller": ["workspace_id": workspace, "surface_id": surface], "focused": [String: Any](),
                    "restore_record": record,
                    "resume_binding": [
                        "kind": "codex", "name": "Codex", "checkpoint_id": checkpoint,
                        "command": "codex resume \(checkpoint)", "cwd": savedDirectory.path,
                        "source": "agent-hook", "resume_evidence_provenance": "tui",
                        "auto_resume": true, "updated_at": 123.5,
                    ],
                ],
            ])
            let cleared = try JSONSerialization.data(withJSONObject: [
                "ok": true, "result": ["cleared": true, "resume_binding": NSNull()],
            ])
            let socket = "/tmp/cmux-cwd-\(UUID().uuidString.prefix(8)).sock"
            let responder = try UnixSocketResponder(path: socket, responses: [response, cleared].map {
                String(decoding: $0, as: UTF8.self)
            })
            defer { responder.stop() }
            let runner = CMUXCLIErrorOutputRegressionTests()
            let result = runner.runProcess(
                executablePath: try runner.bundledCLIPath(),
                arguments: [verb, "--surface", surface, try #require(record["kind"] as? String), checkpoint],
                environment: [
                    "HOME": root.path, "CFFIXED_USER_HOME": root.path,
                    "CODEX_HOME": codexHome.path, "PATH": "\(root.path):/usr/bin:/bin",
                    "SHELL": "/bin/sh", "CMUX_SOCKET_PATH": socket,
                    "CMUX_CLI_SENTRY_DISABLED": "1", "CWD_TEST_LAUNCH_MARKER": marker.path,
                    "AppleLanguages": "(en)", "AppleLocale": "en_US_POSIX",
                    "LANG": "en_US.UTF-8", "LC_ALL": "C",
                ],
                timeout: 15
            )
            let methods = try responder.receivedRequests.map { request in
                let object = try #require(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
                return try #require(object["method"] as? String)
            }
            return (result, methods)
        }

        func expectRefusal(_ result: CMUXCLIErrorOutputRegressionTests.ProcessRunResult, verb: String) {
            #expect(!result.timedOut && result.status == 1, Comment(rawValue: result.diagnostics))
            #expect(result.stderr.contains("cmux \(verb) --surface"), Comment(rawValue: result.diagnostics))
            #expect(!result.stderr.contains(savedDirectory.path), Comment(rawValue: result.diagnostics))
            #expect(!FileManager.default.fileExists(atPath: marker.path), Comment(rawValue: result.diagnostics))
        }
    }
}
