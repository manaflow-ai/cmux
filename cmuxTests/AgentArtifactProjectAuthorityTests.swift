import CmuxAgentChat
import CmuxArtifacts
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Artifact project authority")
struct AgentArtifactProjectAuthorityTests {
    @Test("An unverified working directory cannot select an artifact store")
    func unverifiedWorkingDirectoryFailsClosed() async {
        let store = OutOfOrderCaptureStore(suspendsFirstImport: false)
        let coordinator = AgentArtifactCaptureCoordinator(
            captureService: ArtifactCaptureService(store: store)
        )
        let record = AgentChatSessionRecord(
            sessionID: "observed-session",
            agentKind: .codex,
            workspaceID: "workspace",
            surfaceID: "surface",
            workingDirectory: "/tmp/inherited-project",
            transcriptPath: nil,
            state: .idle,
            lastActivityAt: .now,
            title: nil,
            pid: nil
        )

        #expect(await coordinator.captureContext(for: record) == nil)
    }
}
