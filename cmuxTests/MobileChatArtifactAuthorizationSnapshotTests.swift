import CmuxArtifacts
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Mobile chat artifact authorization snapshot", .serialized)
struct MobileChatArtifactAuthorizationSnapshotTests {
    @MainActor
    @Test("Save stays bound to the session project that authorized the artifact")
    func saveUsesAuthorizedSessionProject() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileChatArtifactAuthorization-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authorizedProject = root.appendingPathComponent("authorized", isDirectory: true)
        let resumedProject = root.appendingPathComponent("resumed", isDirectory: true)
        try FileManager.default.createDirectory(
            at: authorizedProject.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: resumedProject.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let source = authorizedProject.appendingPathComponent("plan.md", isDirectory: false)
        try "authorized plan".write(to: source, atomically: true, encoding: .utf8)
        let transcript = authorizedProject.appendingPathComponent("transcript.jsonl", isDirectory: false)
        let transcriptLines = try [
            claudeLine(type: "assistant", content: [[
                "type": "tool_use",
                "id": "write-plan",
                "name": "Write",
                "input": ["file_path": source.path, "content": "authorized plan"],
            ]]),
            claudeLine(type: "user", content: [[
                "type": "tool_result",
                "tool_use_id": "write-plan",
                "content": "saved",
                "is_error": false,
            ]]),
        ]
        try transcriptLines.joined(separator: "\n").write(
            to: transcript,
            atomically: true,
            encoding: .utf8
        )
        let sessionID = "session-authorization-snapshot"
        let record = AgentChatSessionRecord(
            sessionID: sessionID,
            agentKind: .claude,
            workspaceID: "workspace-authorized",
            surfaceID: nil,
            workingDirectory: authorizedProject.path,
            transcriptPath: transcript.path,
            state: .idle,
            lastActivityAt: .now,
            title: nil,
            pid: nil
        )
        let registry = AgentChatSessionRegistry(restoredRecords: [record])
        let service = AgentChatTranscriptService(
            registry: registry,
            artifactCaptureCoordinator: AgentArtifactCaptureCoordinator(
                captureService: ArtifactCaptureService(store: LocalArtifactRepository())
            )
        )
        let controller = TerminalController.shared
        let previousService = controller.agentChatTranscriptService
        controller.agentChatTranscriptService = service
        defer { controller.agentChatTranscriptService = previousService }

        let resolution = await controller.mobileChatArtifactResolution(
            params: ["session_id": sessionID, "path": source.path],
            operation: .file
        )
        guard case .success(let resolved) = resolution else {
            Issue.record("Expected the transcript snapshot to authorize the artifact")
            return
        }
        registry.noteResumeInitiated(
            sessionID: sessionID,
            source: "claude",
            surfaceID: nil,
            workspaceID: "workspace-resumed",
            workingDirectory: resumedProject.path
        )

        let result = await controller.v2MobileChatArtifactSave(resolved: resolved)
        guard case .ok(let rawPayload) = result,
              let payload = rawPayload as? [String: Any],
              let savedPath = payload["path"] as? String else {
            Issue.record("Expected the authorized artifact save to succeed")
            return
        }
        let authorizedArtifacts = ArtifactStorePaths(projectRoot: authorizedProject).artifactsRoot.path + "/"
        #expect(savedPath.hasPrefix(authorizedArtifacts))
    }

    private func claudeLine(type: String, content: [[String: Any]]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "type": type,
            "isSidechain": false,
            "uuid": UUID().uuidString,
            "timestamp": "2026-07-21T12:00:00.000Z",
            "message": ["role": type == "assistant" ? "assistant" : "user", "content": content],
        ])
        return String(decoding: data, as: UTF8.self)
    }
}
