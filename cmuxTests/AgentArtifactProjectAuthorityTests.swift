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

    @MainActor
    @Test("Process PWD remains readable but cannot authorize persistence")
    func processObservationDoesNotAuthorizePersistence() async throws {
        let registry = AgentChatSessionRegistry()
        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: "observed-session",
                agentKind: .codex,
                surfaceID: "surface",
                workspaceID: "workspace",
                pid: Int(ProcessInfo.processInfo.processIdentifier),
                workingDirectory: "/tmp/inherited-project",
                transcriptPath: nil
            ),
        ])
        let record = try #require(registry.record(sessionID: "observed-session"))
        let coordinator = AgentArtifactCaptureCoordinator(
            captureService: ArtifactCaptureService(
                store: OutOfOrderCaptureStore(suspendsFirstImport: false)
            )
        )

        #expect(record.workingDirectory == "/tmp/inherited-project")
        #expect(record.workingDirectoryAuthority == .processObservation)
        #expect(await coordinator.captureContext(for: record) == nil)
    }

    @Test("Observed launch cwd is preferred but remains non-authoritative")
    func classifiesObservedDirectoryAuthority() {
        let resolver = AgentChatObservedWorkingDirectoryResolver()

        let inherited = resolver.resolve(environment: ["PWD": "/tmp/inherited"])
        let launched = resolver.resolve(environment: [
            "CMUX_AGENT_LAUNCH_CWD": "/project/launch",
            "PWD": "/tmp/inherited",
        ])

        #expect(inherited.path == "/tmp/inherited")
        #expect(inherited.authority == .processObservation)
        #expect(launched.path == "/project/launch")
        #expect(launched.authority == .processObservation)
    }

    @MainActor
    @Test("A cmux resume binding authorizes its project directory")
    func cmuxResumeBindingAuthorizesPersistence() async throws {
        let registry = AgentChatSessionRegistry()
        registry.noteResumeInitiated(
            sessionID: "resumed-session",
            source: "codex",
            surfaceID: "surface",
            workspaceID: "workspace",
            workingDirectory: "/tmp/cmux-authoritative-project"
        )
        let record = try #require(registry.record(sessionID: "resumed-session"))
        let coordinator = AgentArtifactCaptureCoordinator(
            captureService: ArtifactCaptureService(
                store: OutOfOrderCaptureStore(suspendsFirstImport: false)
            )
        )

        #expect(record.workingDirectoryAuthority == .cmuxLaunch)
        #expect(await coordinator.captureContext(for: record) != nil)
    }
}
