import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class RestorableCodexForkTagTests: XCTestCase {
    func testRestoredCodexForkPreservesPromptTagsWhenForkedAgain() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-codex-fork-tags-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let dir = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let workspaceId = UUID()
        let panelId = UUID()
        let sessionId = "019ef275-74e3-7777-9773-9dcb118ed5ad"
        try writeHookStore(
            root: root,
            sessions: [
                sessionId: [
                    "sessionId": sessionId,
                    "workspaceId": workspaceId.uuidString,
                    "surfaceId": panelId.uuidString,
                    "cwd": dir.path,
                    "pid": NSNull(),
                    "isRestorable": true,
                    "updatedAt": 10,
                    "launchCommand": [
                        "launcher": "codex",
                        "executablePath": "/usr/local/bin/codex",
                        "arguments": [
                            "/usr/local/bin/codex",
                            "fork",
                            "019ef275-74e3-7777-9773-9dcb118ed5ac",
                            "tag-one",
                            "tag two",
                            "--model",
                            "gpt-5",
                        ],
                        "workingDirectory": dir.path,
                        "capturedAt": 10,
                        "source": "environment",
                    ],
                ],
            ]
        )

        let snapshot = try XCTUnwrap(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
                .snapshot(workspaceId: workspaceId, panelId: panelId)
        )
        let fork = try XCTUnwrap(snapshot.forkCommand)
        XCTAssertTrue(
            fork.contains("'fork' '\(sessionId)' 'tag-one' 'tag two' '--model' 'gpt-5'"),
            "forking a restored forked session must preserve every prompt tag; got: \(fork)"
        )
    }

    private func writeHookStore(root: URL, sessions: [String: [String: Any]]) throws {
        let stateDir = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: ["version": 1, "sessions": sessions],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: stateDir.appendingPathComponent("codex-hook-sessions.json"), options: .atomic)
    }
}
