import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@MainActor
@Suite("Agent chat session registry")
struct AgentChatSessionRegistryTests {
    @Test("visible-terminal lookup follows binding updates")
    func visibleTerminalLookupFollowsBindingUpdates() {
        let registry = AgentChatSessionRegistry()
        registry.adoptDetectedSession(
            sessionID: "older",
            agentKind: .claude,
            workspaceID: "workspace-visible",
            surfaceID: "terminal-one",
            workingDirectory: nil,
            transcriptPath: nil,
            at: Date(timeIntervalSince1970: 100)
        )
        registry.adoptDetectedSession(
            sessionID: "newer",
            agentKind: .codex,
            workspaceID: "workspace-visible",
            surfaceID: "terminal-two",
            workingDirectory: nil,
            transcriptPath: nil,
            at: Date(timeIntervalSince1970: 200)
        )

        registry.update(sessionID: "older") { record in
            record.workspaceID = "workspace-hidden"
            record.surfaceID = "terminal-moved"
        }

        let visible = registry.sessions(
            workspaceAndSurfaceIDs: ["workspace-visible": ["terminal-one", "terminal-two"]]
        )
        #expect(visible.map(\.sessionID) == ["newer"])

        let moved = registry.sessions(
            workspaceAndSurfaceIDs: ["workspace-hidden": ["terminal-moved"]]
        )
        #expect(moved.map(\.sessionID) == ["older"])
    }

    @Test("title adoption reuses a live session already bound to the surface")
    func titleAdoptionReusesLiveSurfaceBinding() {
        let registry = AgentChatSessionRegistry()
        let original = registry.adoptDetectedSession(
            sessionID: "existing",
            agentKind: .claude,
            workspaceID: "workspace-a",
            surfaceID: "terminal-shared",
            workingDirectory: nil,
            transcriptPath: nil,
            at: Date(timeIntervalSince1970: 100)
        )

        let adopted = registry.adoptDetectedSession(
            sessionID: "candidate",
            agentKind: .claude,
            workspaceID: "workspace-b",
            surfaceID: "terminal-shared",
            workingDirectory: nil,
            transcriptPath: nil,
            at: Date(timeIntervalSince1970: 200)
        )

        #expect(adopted.sessionID == original.sessionID)
        #expect(registry.record(sessionID: "candidate")?.sessionID == nil)
    }

    @Test("live surface lookup follows binding and state changes")
    func liveSurfaceLookupFollowsBindingAndStateChanges() {
        let registry = AgentChatSessionRegistry()
        registry.adoptDetectedSession(
            sessionID: "session-a",
            agentKind: .claude,
            workspaceID: "workspace-a",
            surfaceID: "terminal-a",
            workingDirectory: nil,
            transcriptPath: nil,
            at: Date(timeIntervalSince1970: 100)
        )

        #expect(registry.hasLiveSession(workspaceID: "workspace-a", surfaceID: "terminal-a"))

        registry.update(sessionID: "session-a") { record in
            record.workspaceID = "workspace-b"
            record.surfaceID = "terminal-b"
        }

        #expect(!registry.hasLiveSession(workspaceID: "workspace-a", surfaceID: "terminal-a"))
        #expect(registry.hasLiveSession(workspaceID: "workspace-b", surfaceID: "terminal-b"))

        registry.update(sessionID: "session-a") { record in
            record.state = .ended
        }

        #expect(!registry.hasLiveSession(workspaceID: "workspace-b", surfaceID: "terminal-b"))
    }

    @Test("title adoption sweeps stale surface bindings")
    func titleAdoptionSweepsStaleSurfaceBindings() {
        let registry = AgentChatSessionRegistry()
        registry.adoptDetectedSession(
            sessionID: "stale",
            agentKind: .claude,
            workspaceID: "workspace-a",
            surfaceID: "terminal-a",
            workingDirectory: nil,
            transcriptPath: nil,
            at: Date(timeIntervalSince1970: 100)
        )
        registry.update(sessionID: "stale") { record in
            record.pid = Int(Int32.max)
        }

        let adopted = registry.adoptDetectedSession(
            sessionID: "fresh",
            agentKind: .claude,
            workspaceID: "workspace-b",
            surfaceID: "terminal-a",
            workingDirectory: nil,
            transcriptPath: nil,
            at: Date(timeIntervalSince1970: 200)
        )

        #expect(adopted.sessionID == "fresh")
        #expect(registry.record(sessionID: "stale")?.state == .ended)
    }
}
