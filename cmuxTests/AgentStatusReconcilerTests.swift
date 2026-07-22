import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent status reconciliation")
struct AgentStatusReconcilerTests {
    private let reconciler = AgentStatusReconciler()
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test func lostStopCannotPinRunningForever() {
        let evidence = AgentStatusEvidence(
            lifecycle: .running,
            lifecycleObservedAt: now.addingTimeInterval(-121),
            shellActivity: .commandRunning
        )

        let resolution = reconciler.resolve(
            evidence: evidence,
            statusKey: "codex",
            hasLiveRuntime: true,
            now: now
        )

        #expect(resolution == AgentStatusResolution(lifecycle: .unknown, confidence: .uncertain))
    }

    @Test func recentOutputFromMatchingForegroundAgentInfersRunning() {
        let evidence = AgentStatusEvidence(
            lifecycle: .running,
            lifecycleObservedAt: now.addingTimeInterval(-121),
            outputObservedAt: now.addingTimeInterval(-2),
            foregroundAgentStatusKey: "codex",
            foregroundObservedAt: now.addingTimeInterval(-2),
            shellActivity: .commandRunning
        )

        let resolution = reconciler.resolve(
            evidence: evidence,
            statusKey: "codex",
            hasLiveRuntime: true,
            now: now
        )

        #expect(resolution == AgentStatusResolution(lifecycle: .running, confidence: .inferred))
    }

    @Test func unrelatedForegroundOutputCannotKeepAgentRunning() {
        let evidence = AgentStatusEvidence(
            lifecycle: .running,
            lifecycleObservedAt: now.addingTimeInterval(-121),
            outputObservedAt: now.addingTimeInterval(-2),
            foregroundAgentStatusKey: "claude_code",
            foregroundObservedAt: now.addingTimeInterval(-2),
            shellActivity: .commandRunning
        )

        let resolution = reconciler.resolve(
            evidence: evidence,
            statusKey: "codex",
            hasLiveRuntime: true,
            now: now
        )

        #expect(resolution == AgentStatusResolution(lifecycle: .unknown, confidence: .uncertain))
    }

    @Test func promptIdleOverridesRecentTerminalActivity() {
        let evidence = AgentStatusEvidence(
            lifecycle: .running,
            lifecycleObservedAt: now,
            outputObservedAt: now,
            foregroundAgentStatusKey: "codex",
            foregroundObservedAt: now,
            shellActivity: .promptIdle
        )

        let resolution = reconciler.resolve(
            evidence: evidence,
            statusKey: "codex",
            hasLiveRuntime: true,
            now: now
        )

        #expect(resolution == AgentStatusResolution(lifecycle: .idle, confidence: .confident))
    }

    @Test func deadRuntimeRemovesDerivedStatus() {
        let evidence = AgentStatusEvidence(
            lifecycle: .running,
            lifecycleObservedAt: now,
            shellActivity: .commandRunning
        )

        let resolution = reconciler.resolve(
            evidence: evidence,
            statusKey: "codex",
            hasLiveRuntime: false,
            now: now
        )

        #expect(resolution == nil)
    }

    @Test func freshNeedsInputRemainsConfidentDuringPromptRendering() {
        let signalTime = now.addingTimeInterval(-2)
        let evidence = AgentStatusEvidence(
            lifecycle: .needsInput,
            lifecycleObservedAt: signalTime,
            outputObservedAt: signalTime.addingTimeInterval(1),
            foregroundAgentStatusKey: "codex",
            foregroundObservedAt: now,
            shellActivity: .commandRunning
        )

        let resolution = reconciler.resolve(
            evidence: evidence,
            statusKey: "codex",
            hasLiveRuntime: true,
            now: now
        )

        #expect(resolution == AgentStatusResolution(lifecycle: .needsInput, confidence: .confident))
    }

    @Test func staleNeedsInputDegradesHonestly() {
        let evidence = AgentStatusEvidence(
            lifecycle: .needsInput,
            lifecycleObservedAt: now.addingTimeInterval(-301),
            foregroundAgentStatusKey: "codex",
            foregroundObservedAt: now,
            shellActivity: .commandRunning
        )

        let resolution = reconciler.resolve(
            evidence: evidence,
            statusKey: "codex",
            hasLiveRuntime: true,
            now: now
        )

        #expect(resolution == AgentStatusResolution(lifecycle: .unknown, confidence: .uncertain))
    }

    @Test func codexPermissionTelemetryCarriesNeedsInputWithoutBecomingActionable() throws {
        let event = WorkstreamEvent(
            sessionId: "codex-session",
            hookEventName: .preToolUse,
            source: "codex",
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString,
            receivedAt: now,
            extraFieldsJSON: #"{"_cmux_agent_status_signal":"needsInput"}"#
        )

        let signal = try #require(AgentStatusHookEventSignal(event: event))

        #expect(signal.statusKey == "codex")
        #expect(signal.lifecycle == .needsInput)
        #expect(signal.observedAt == now)
        #expect(FeedCoordinator.isBlockingDecisionEvent(event.hookEventName) == false)
    }
}
