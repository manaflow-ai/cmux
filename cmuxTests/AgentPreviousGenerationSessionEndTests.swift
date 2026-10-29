import CmuxFoundation
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression tests for https://github.com/manaflow-ai/cmux/issues/21226: a
/// spooled SessionEnd from an agent the previous app instance's quit killed
/// must not clear the resume binding the current instance restored.
@Suite(.serialized)
struct AgentPreviousGenerationSessionEndTests {
    private static let appIdentity = AgentPIDProcessIdentity(pid: getpid())

    @MainActor
    private func preserve(
        identity: AgentPIDProcessIdentity,
        localProcess: Bool?
    ) -> Bool? {
        var params: [String: Any] = [
            "workspace_id": UUID().uuidString,
            "surface_id": UUID().uuidString,
            "session_id": "previous-generation-session",
            "pid": Int(identity.pid),
            "pid_start_seconds": identity.startSeconds,
            "pid_start_microseconds": identity.startMicroseconds,
        ]
        if let localProcess {
            params["local_process"] = localProcess
        }
        guard case .ok(let payload) = TerminalController.shared.v2AgentHibernationSessionEnd(params: params),
              let result = payload as? [String: Any] else {
            return nil
        }
        return result["preserve"] as? Bool
    }

    @MainActor
    @Test
    func preservesSessionEndFromLocalProcessThatPredatesAppLaunch() throws {
        let app = try #require(Self.appIdentity)
        let previousGeneration = AgentPIDProcessIdentity(
            pid: 45692,
            startSeconds: app.startSeconds - 60,
            startMicroseconds: app.startMicroseconds
        )
        #expect(preserve(identity: previousGeneration, localProcess: true) == true)
    }

    @MainActor
    @Test
    func endsSessionFromLocalProcessStartedAfterAppLaunch() throws {
        let app = try #require(Self.appIdentity)
        let currentGeneration = AgentPIDProcessIdentity(
            pid: 45693,
            startSeconds: app.startSeconds + 60,
            startMicroseconds: app.startMicroseconds
        )
        #expect(preserve(identity: currentGeneration, localProcess: true) == false)
    }

    /// A process that predates the app and is still running, such as an agent
    /// under a tmux server that outlived the quit, reports its own real exit.
    @MainActor
    @Test
    func endsSessionFromLiveProcessThatPredatesAppLaunch() throws {
        let app = try #require(Self.appIdentity)
        let launchd = try #require(AgentPIDProcessIdentity(pid: 1))
        #expect(launchd.started(before: app))
        #expect(preserve(identity: launchd, localProcess: true) == false)
    }

    /// Relay and older hook processes do not vouch that the PID is local, so a
    /// local process clock cannot judge them.
    @MainActor
    @Test
    func ignoresLaunchOrderWithoutLocalProcessClaim() throws {
        let app = try #require(Self.appIdentity)
        let earlier = AgentPIDProcessIdentity(
            pid: 45694,
            startSeconds: app.startSeconds - 60,
            startMicroseconds: app.startMicroseconds
        )
        #expect(preserve(identity: earlier, localProcess: nil) == false)
        #expect(preserve(identity: earlier, localProcess: false) == false)
    }
}
