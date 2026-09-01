import Foundation
import Testing

@Suite("Agent surface resume publication retry")
struct AgentSurfaceResumePublicationRetryTests {
    private let desired: [String: Any] = [
        "kind": "claude",
        "checkpoint_id": "session-a",
        "source": "agent-hook",
        "command": "claude --resume session-a",
    ]

    @Test
    func preflightGuardsObservedGeneration() throws {
        let preflight = try #require(AgentSurfaceResumePublicationRetry().preflight(
            desiredParams: desired,
            currentPayload: [
                "resume_binding": [
                    "kind": "claude",
                    "checkpoint_id": "session-old",
                    "source": "agent-hook",
                    "updated_at": 5.0,
                ],
            ]
        ))

        #expect(preflight.generation == .updatedAt(5))
        #expect(preflight.params["_cmux_expected_binding_updated_at"] as? Double == 5)
        #expect(preflight.params["_cmux_expect_missing_binding"] == nil)
    }

    @Test
    func recognizesCommittedPublicationAsAlreadyApplied() {
        let decision = AgentSurfaceResumePublicationRetry().decision(
            desiredParams: desired,
            currentPayload: [
                "resume_binding": [
                    "kind": "claude",
                    "checkpoint_id": "session-a",
                    "source": "agent-hook",
                    "updated_at": 12.0,
                ],
            ],
            baselineGeneration: .updatedAt(5)
        )

        guard case .alreadyApplied = decision else {
            Issue.record("Expected an already-applied decision")
            return
        }
    }

    @Test
    func unchangedOlderGenerationRetriesConditionally() {
        let decision = AgentSurfaceResumePublicationRetry().decision(
            desiredParams: desired,
            currentPayload: [
                "resume_binding": [
                    "kind": "claude",
                    "checkpoint_id": "session-old",
                    "source": "agent-hook",
                    "updated_at": 5.0,
                ],
            ],
            baselineGeneration: .updatedAt(5)
        )

        guard case .retry(let params) = decision else {
            Issue.record("Expected a conditional retry")
            return
        }
        #expect(params["_cmux_expected_binding_updated_at"] as? Double == 5)
    }

    @Test
    func missingBindingUsesMissingGenerationGuard() throws {
        let retry = AgentSurfaceResumePublicationRetry()
        let preflight = try #require(retry.preflight(
            desiredParams: desired,
            currentPayload: ["resume_binding": NSNull()]
        ))
        #expect(preflight.generation == .missing)
        #expect(preflight.params["_cmux_expect_missing_binding"] as? Bool == true)

        let decision = retry.decision(
            desiredParams: desired,
            currentPayload: ["resume_binding": NSNull()],
            baselineGeneration: preflight.generation
        )
        guard case .superseded = decision else {
            Issue.record("Expected a missing baseline to fail closed")
            return
        }
    }

    @Test
    func ownerGenerationRejectsSameTimestampReplacement() throws {
        let retry = AgentSurfaceResumePublicationRetry()
        let baseline = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        let replacement = try #require(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
        let preflight = try #require(retry.preflight(
            desiredParams: desired,
            currentPayload: [
                "resume_binding": [
                    "kind": "claude",
                    "checkpoint_id": "session-old",
                    "source": "agent-hook",
                    "updated_at": 5.0,
                ],
                "resume_binding_generation": baseline.uuidString,
            ]
        ))

        #expect(preflight.generation == .owner(baseline))
        #expect(preflight.params["_cmux_expected_binding_generation"] as? String == baseline.uuidString)
        #expect(preflight.params["_cmux_expected_binding_updated_at"] == nil)

        let decision = retry.decision(
            desiredParams: desired,
            currentPayload: [
                "resume_binding": [
                    "kind": "claude",
                    "checkpoint_id": "session-new",
                    "source": "agent-hook",
                    "updated_at": 5.0,
                ],
                "resume_binding_generation": replacement.uuidString,
            ],
            baselineGeneration: preflight.generation
        )
        guard case .superseded = decision else {
            Issue.record("A changed owner token must suppress the retry even when timestamps tie")
            return
        }
    }

    @Test
    func unchangedEmptyOwnerGenerationCanRetry() throws {
        let retry = AgentSurfaceResumePublicationRetry()
        let generation = try #require(UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"))
        let decision = retry.decision(
            desiredParams: desired,
            currentPayload: [
                "resume_binding": NSNull(),
                "resume_binding_generation": generation.uuidString,
            ],
            baselineGeneration: .owner(generation)
        )
        guard case .retry(let params) = decision else {
            Issue.record("An unchanged app-owned empty owner must remain retryable")
            return
        }
        #expect(params["_cmux_expected_binding_generation"] as? String == generation.uuidString)
        #expect(params["_cmux_expect_missing_binding"] == nil)
    }

    @Test
    func malformedOwnerGenerationFailsClosed() {
        let decision = AgentSurfaceResumePublicationRetry().decision(
            desiredParams: desired,
            currentPayload: [
                "resume_binding": [
                    "kind": "claude",
                    "checkpoint_id": "session-old",
                    "source": "agent-hook",
                    "updated_at": 5.0,
                ],
                "resume_binding_generation": "not-a-uuid",
            ],
            baselineGeneration: .updatedAt(5)
        )
        guard case .superseded = decision else {
            Issue.record("A malformed owner token must not fall back to a timestamp CAS")
            return
        }
    }

    @Test
    func bindingOwnershipRejectsUnrelatedOrIncompletePayloads() {
        let ownership = AgentSurfaceResumeBindingOwnership(
            kind: "Kiro",
            sessionId: "session-a"
        )
        #expect(
            ownership.evaluate([
                "source": "agent-hook",
                "kind": "kiro",
                "checkpoint_id": "session-a",
            ]) == .matches
        )
        #expect(
            ownership.evaluate([
                "source": "agent-hook",
                "kind": "kiro",
                "checkpoint_id": "session-b",
            ]) == .doesNotMatch
        )
        #expect(
            ownership.evaluate([
                "source": "agent-hook",
                "kind": "kiro",
            ]) == .unavailable
        )
        #expect(
            ownership.evaluate([
                "source": "manual",
                "kind": "kiro",
                "checkpoint_id": "session-a",
            ]) == .doesNotMatch
        )
    }

    @Test
    func changedGenerationSupersedesRetry() {
        let decision = AgentSurfaceResumePublicationRetry().decision(
            desiredParams: desired,
            currentPayload: [
                "resume_binding": [
                    "kind": "claude",
                    "checkpoint_id": "session-b",
                    "source": "agent-hook",
                    "updated_at": 15.0,
                ],
            ],
            baselineGeneration: .updatedAt(5)
        )

        guard case .superseded = decision else {
            Issue.record("Expected the changed generation to suppress retry")
            return
        }
    }

    @Test
    func olderSameSessionRetriesMetadataConditionally() {
        let decision = AgentSurfaceResumePublicationRetry().decision(
            desiredParams: desired,
            currentPayload: [
                "resume_binding": [
                    "kind": "claude",
                    "checkpoint_id": "session-a",
                    "source": "agent-hook",
                    "updated_at": 5.0,
                ],
            ],
            baselineGeneration: .updatedAt(5)
        )

        guard case .retry(let params) = decision else {
            Issue.record("Expected stale same-session metadata to retry")
            return
        }
        #expect(params["_cmux_expected_binding_updated_at"] as? Double == 5)
    }
}
