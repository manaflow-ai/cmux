import CmuxAgentChat
import CmuxArtifacts
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Automatic artifact transcript path bounds")
struct AgentArtifactAutomaticPathBoundTests {
    @MainActor
    @Test("Automatic Codex capture does not scan the sessions tree without a recorded path")
    func codexCaptureRequiresAnAuthoritativeTranscriptPath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-artifact-path-bound-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let sessionsDay = codexHome.appendingPathComponent("sessions/2026/07/21", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessionsDay, withIntermediateDirectories: true)
        let artifact = root.appendingPathComponent("generated-plan.md", isDirectory: false)
        try "plan".write(to: artifact, atomically: true, encoding: .utf8)
        let sessionID = "019f8c1c-1111-7222-8333-444444444444"
        let transcript = sessionsDay.appendingPathComponent(
            "rollout-2026-07-21T00-00-00-\(sessionID).jsonl",
            isDirectory: false
        )
        try codexArtifactLine(path: artifact.path)
            .write(to: transcript, atomically: true, encoding: .utf8)
        let repository = LocalArtifactRepository()
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(
                homeDirectory: root,
                environment: ["CODEX_HOME": codexHome.path]
            ),
            artifactCaptureCoordinator: AgentArtifactCaptureCoordinator(
                captureService: ArtifactCaptureService(store: repository)
            )
        )
        let record = AgentChatSessionRecord(
            sessionID: sessionID,
            agentKind: .codex,
            workspaceID: "workspace",
            surfaceID: nil,
            workingDirectory: projectRoot.path,
            transcriptPath: nil,
            state: .idle,
            lastActivityAt: .now,
            title: nil,
            pid: nil
        )

        service.scheduleArtifactCapture(for: record)
        let task = try #require(service.artifactCaptureTasks[sessionID]?.task)
        await task.value

        #expect(!FileManager.default.fileExists(
            atPath: ArtifactStorePaths(projectRoot: projectRoot).filesystemRoot.path
        ))
    }

    private func codexArtifactLine(path: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "timestamp": "2026-07-21T12:00:00.000Z",
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "assistant",
                "content": [["type": "output_text", "text": "Saved artifact to \(path)"]],
            ],
        ])
        return String(decoding: data, as: UTF8.self)
    }
}
