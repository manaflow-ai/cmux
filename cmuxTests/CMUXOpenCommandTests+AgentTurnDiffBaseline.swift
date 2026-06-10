import Darwin
import Foundation
import XCTest


// MARK: - Agent turn diff baseline
extension CMUXOpenCommandTests {
    func testAgentTurnDiffBaselineStoresUntrackedSnapshotsOutsideGit() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let stateURL = rootURL.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try runGit(["init"], in: repoURL)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
        try "tracked\n".write(to: repoURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "tracked.txt"], in: repoURL)
        try runGit(["commit", "-m", "initial"], in: repoURL)
        let secretURL = repoURL.appendingPathComponent("secret.txt")
        try "before\n".write(to: secretURL, atomically: true, encoding: .utf8)
        chmod(secretURL.path, 0o644)

        let workspaceId = UUID().uuidString.lowercased()
        let surfaceId = UUID().uuidString.lowercased()
        let socketPath = makeSocketPath("hook-diff")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            if method == "surface.list" {
                return Self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": [
                            [
                                "id": surfaceId,
                                "ref": "surface:1",
                                "index": 1,
                                "focused": true
                            ] as [String: Any]
                        ]
                    ]
                )
            }
            return Self.v2Response(id: id, ok: true, result: [:])
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["hooks", "codex", "prompt-submit", "--workspace", workspaceId, "--surface", surfaceId],
            environmentOverrides: [
                "CMUX_AGENT_HOOK_STATE_DIR": stateURL.path,
                "PWD": repoURL.path
            ],
            currentDirectoryURL: repoURL
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let untrackedRefs = try runGitStdout(
            ["for-each-ref", "--format=%(refname)", "refs/cmux/last-turn/untracked"],
            in: repoURL
        )
        XCTAssertEqual(untrackedRefs.trimmingCharacters(in: .whitespacesAndNewlines), "")

        let storeURL = stateURL.appendingPathComponent("agent-turn-diff-baselines.json")
        let lockURL = stateURL.appendingPathComponent("agent-turn-diff-baselines.json.lock")
        let storeData = try Data(contentsOf: storeURL)
        let store = try JSONSerialization.jsonObject(with: storeData, options: []) as? [String: Any]
        let records = try XCTUnwrap(store?["records"] as? [[String: Any]])
        let record = try XCTUnwrap(records.first)
        let snapshotId = try XCTUnwrap(record["untrackedSnapshotId"] as? String)
        let hashes = try XCTUnwrap(record["untrackedPathHashes"] as? [String: String])
        XCTAssertNotNil(hashes["secret.txt"])
        let snapshotRoot = stateURL
            .appendingPathComponent("agent-turn-diff-baseline-snapshots", isDirectory: true)
        let snapshotDirectory = snapshotRoot
            .appendingPathComponent(snapshotId, isDirectory: true)
        let filesDirectory = snapshotDirectory
            .appendingPathComponent("files", isDirectory: true)
        let snapshotFile = filesDirectory
            .appendingPathComponent("secret.txt", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotFile.path))
        XCTAssertEqual(try posixPermissions(at: stateURL), 0o700)
        XCTAssertEqual(try posixPermissions(at: storeURL), 0o600)
        XCTAssertEqual(try posixPermissions(at: lockURL), 0o600)
        XCTAssertEqual(try posixPermissions(at: snapshotRoot), 0o700)
        XCTAssertEqual(try posixPermissions(at: snapshotDirectory), 0o700)
        XCTAssertEqual(try posixPermissions(at: filesDirectory), 0o700)
        XCTAssertEqual(try posixPermissions(at: snapshotFile), 0o600)
    }

    func testAgentTurnDiffBaselineUsesEmptyTreeForUnbornGitRepo() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let stateURL = rootURL.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try runGit(["init"], in: repoURL)
        let emptyTree = try runGitStdout(["hash-object", "-t", "tree", "/dev/null"], in: repoURL)

        let workspaceId = UUID().uuidString.lowercased()
        let surfaceId = UUID().uuidString.lowercased()
        let socketPath = makeSocketPath("hook-empty")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            if method == "surface.list" {
                return Self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": [
                            [
                                "id": surfaceId,
                                "ref": "surface:1",
                                "index": 1,
                                "focused": true
                            ] as [String: Any]
                        ]
                    ]
                )
            }
            return Self.v2Response(id: id, ok: true, result: [:])
        }

        let hook = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["hooks", "codex", "prompt-submit", "--workspace", workspaceId, "--surface", surfaceId],
            environmentOverrides: [
                "CMUX_AGENT_HOOK_STATE_DIR": stateURL.path,
                "PWD": repoURL.path
            ],
            currentDirectoryURL: repoURL
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(hook.timedOut, hook.stderr)
        XCTAssertEqual(hook.status, 0, hook.stderr)

        let storeURL = stateURL.appendingPathComponent("agent-turn-diff-baselines.json")
        let storeData = try Data(contentsOf: storeURL)
        let store = try XCTUnwrap(JSONSerialization.jsonObject(with: storeData) as? [String: Any])
        let records = try XCTUnwrap(store["records"] as? [[String: Any]])
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record["baseCommit"] as? String, emptyTree)

        try "created before first commit\n".write(
            to: repoURL.appendingPathComponent("new-file.txt"),
            atomically: true,
            encoding: .utf8
        )

        let lastTurn = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--last-turn"],
            environmentOverrides: [
                "CMUX_AGENT_HOOK_STATE_DIR": stateURL.path,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId
            ],
            currentDirectoryURL: repoURL
        )
        XCTAssertTrue(lastTurn.patch.contains("new-file.txt"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("+created before first commit"), lastTurn.patch)
    }

    func testAgentTurnDiffBaselineKeepsFirstSnapshotForDuplicateTurnHook() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let stateURL = rootURL.appendingPathComponent("state", isDirectory: true)
        let fileURL = repoURL.appendingPathComponent("story.txt")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try runGit(["init"], in: repoURL)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
        try "one\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "story.txt"], in: repoURL)
        try runGit(["commit", "-m", "initial"], in: repoURL)

        let workspaceId = UUID().uuidString.lowercased()
        let surfaceId = UUID().uuidString.lowercased()
        let sessionId = "session-duplicate-turn"
        let turnId = "turn-duplicate"

        func runHook(subcommand: String, input: [String: Any]) throws -> ProcessRunResult {
            let socketPath = makeSocketPath("hookdu")
            let listenerFD = try bindUnixSocket(at: socketPath)
            let state = MockSocketServerState()
            defer {
                Darwin.close(listenerFD)
                unlink(socketPath)
            }
            let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
                guard let payload = Self.v2Payload(from: line),
                      let id = payload["id"] as? String,
                      let method = payload["method"] as? String else {
                    return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
                }
                if method == "surface.list" {
                    return Self.v2Response(
                        id: id,
                        ok: true,
                        result: [
                            "surfaces": [
                                [
                                    "id": surfaceId,
                                    "ref": "surface:1",
                                    "index": 1,
                                    "focused": true
                                ] as [String: Any]
                            ]
                        ]
                    )
                }
                return Self.v2Response(id: id, ok: true, result: [:])
            }
            let inputData = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
            let result = runCLI(
                cliPath: cliPath,
                socketPath: socketPath,
                arguments: ["hooks", "codex", subcommand, "--workspace", workspaceId, "--surface", surfaceId],
                environmentOverrides: [
                    "CMUX_AGENT_HOOK_STATE_DIR": stateURL.path,
                    "PWD": repoURL.path
                ],
                currentDirectoryURL: repoURL,
                stdinText: String(data: inputData, encoding: .utf8)
            )
            wait(for: [serverHandled], timeout: 5)
            return result
        }

        func runPromptSubmit() throws -> ProcessRunResult {
            try runHook(
                subcommand: "prompt-submit",
                input: [
                    "session_id": sessionId,
                    "turn_id": turnId,
                    "cwd": repoURL.path
                ]
            )
        }

        func runStop() throws -> ProcessRunResult {
            try runHook(
                subcommand: "stop",
                input: [
                    "session_id": sessionId,
                    "turn_id": turnId,
                    "cwd": repoURL.path,
                    "last_assistant_message": "done"
                ]
            )
        }

        func diffBaselineRecords() throws -> [[String: Any]] {
            let storeData = try Data(contentsOf: stateURL.appendingPathComponent("agent-turn-diff-baselines.json"))
            let store = try JSONSerialization.jsonObject(with: storeData, options: []) as? [String: Any]
            return try XCTUnwrap(store?["records"] as? [[String: Any]])
        }

        let firstHook = try runPromptSubmit()
        XCTAssertFalse(firstHook.timedOut, firstHook.stderr)
        XCTAssertEqual(firstHook.status, 0, firstHook.stderr)
        try "one\ntwo\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let duplicateHook = try runPromptSubmit()
        XCTAssertFalse(duplicateHook.timedOut, duplicateHook.stderr)
        XCTAssertEqual(duplicateHook.status, 0, duplicateHook.stderr)

        let records = try diffBaselineRecords()
        XCTAssertEqual(records.filter { $0["turnId"] as? String == turnId }.count, 1)
        let duplicateBaseCommit = try XCTUnwrap(records.first?["baseCommit"] as? String)

        let lastTurn = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--last-turn"],
            environmentOverrides: [
                "CMUX_AGENT_HOOK_STATE_DIR": stateURL.path,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId
            ],
            currentDirectoryURL: repoURL
        )
        XCTAssertTrue(lastTurn.patch.contains("+two"), lastTurn.patch)

        let stopHook = try runStop()
        XCTAssertFalse(stopHook.timedOut, stopHook.stderr)
        XCTAssertEqual(stopHook.status, 0, stopHook.stderr)
        try "one\ntwo\nthree\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let nextHook = try runPromptSubmit()
        XCTAssertFalse(nextHook.timedOut, nextHook.stderr)
        XCTAssertEqual(nextHook.status, 0, nextHook.stderr)

        let refreshedRecords = try diffBaselineRecords()
        XCTAssertEqual(refreshedRecords.filter { $0["turnId"] as? String == turnId }.count, 1)
        let refreshedBaseCommit = try XCTUnwrap(refreshedRecords.first?["baseCommit"] as? String)
        XCTAssertNotEqual(refreshedBaseCommit, duplicateBaseCommit)
    }

}
