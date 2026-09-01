import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct AgentLifecycleEventTests {
    @Test
    func lifecycleMutationPublishesSemanticStateWithSessionIdentity() throws {
        let fixture = try Fixture()

        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-one"
        )

        let event = try #require(fixture.agentEvents().only)
        let payload = try #require(event["payload"] as? [String: Any])
        #expect(event["name"] as? String == "agent.state.changed")
        #expect(event["category"] as? String == "agent")
        #expect(event["source"] as? String == "agent.lifecycle")
        #expect(event["workspace_id"] as? String == fixture.workspace.id.uuidString)
        #expect(event["surface_id"] as? String == fixture.surfaceID.uuidString)
        #expect(payload["agent"] as? String == "codex")
        #expect(payload["state"] as? String == "running")
        #expect(payload["session_id"] as? String == "session-one")
        #expect(CmuxEventBus.int64(payload["revision"]) == 1)
    }

    @Test
    func explicitSessionMutationGuardPrefersProcessGeneration() throws {
        let identity = try #require(AgentHookProcessIdentity(livePID: Int(getpid())))
        let guardValue = CMUXCLI(args: []).agentMutationGuard(
            key: "codex",
            sessionID: "session-reused",
            expectedPIDKey: "codex.session-reused",
            expectedPID: identity.pid,
            expectedProcessIdentity: identity
        )

        #expect(guardValue == .process(
            statusKey: "codex",
            pidKey: "codex.session-reused",
            pid: Int32(identity.pid),
            startSeconds: identity.startSeconds,
            startMicroseconds: identity.startMicroseconds
        ))
    }

    @Test
    func explicitSessionMutationGuardFallsBackWhenProcessGenerationIsUnavailable() {
        let guardValue = CMUXCLI(args: []).agentMutationGuard(
            key: "claude",
            sessionID: "provider-session",
            expectedPIDKey: "claude.provider-session",
            expectedPID: 62_6262,
            expectedProcessIdentity: nil
        )

        #expect(
            guardValue == .session(
                statusKey: "claude",
                sessionID: "provider-session"
            )
        )
    }

    @Test
    func staleRelayAttemptCannotReclaimLifecycleOwner() throws {
        let fixture = try Fixture()
        let terminal = try #require(
            fixture.workspace.panels[fixture.surfaceID] as? TerminalPanel
        )
        let terminalLifecycleID = terminal.surface.terminalLifecycleId
        let currentAttemptID = UUID()
        fixture.workspace.remoteTerminalAttemptIDsBySurfaceId[fixture.surfaceID]
            = currentAttemptID
        let currentSessionID = "session#relay#\(terminalLifecycleID.uuidString)"
            + "#\(currentAttemptID.uuidString)#43210#123#456"
        let owner = ControlSidebarPanelOwner.workspace(fixture.workspace)

        #expect(owner.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: currentSessionID,
            startsNewOccupant: true
        ))

        let sameProcessAlias = "alias#relay#\(terminalLifecycleID.uuidString)"
            + "#\(currentAttemptID.uuidString)#43210#123#456"
        #expect(owner.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: sameProcessAlias,
            startsNewOccupant: true
        ))

        let staleSessionID = "session#relay#\(terminalLifecycleID.uuidString)"
            + "#\(UUID().uuidString)#43100#122#789"
        #expect(!owner.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .idle,
            sessionID: staleSessionID,
            startsNewOccupant: true
        ))
        let sameAttemptOlderProcess = "session#relay#\(terminalLifecycleID.uuidString)"
            + "#\(currentAttemptID.uuidString)#43100#122#789"
        #expect(!owner.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .idle,
            sessionID: sameAttemptOlderProcess,
            startsNewOccupant: true
        ))
        #expect(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]?
                .sessionID == sameProcessAlias
        )
    }

    @Test
    func nonStartLifecycleMutationCannotRecreateClearedOwner() throws {
        let fixture = try Fixture()
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-one",
            startsNewOccupant: true
        )
        #expect(fixture.workspace.clearAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            expectedSessionID: "session-one"
        ))
        let sequence = CmuxEventBus.shared.latestSequence

        #expect(!fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .idle,
            sessionID: "session-one",
            requireExistingOwner: true
        ))
        #expect(fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"] == nil)
        #expect(fixture.agentEvents(after: sequence).isEmpty)
    }

    @Test
    func verifiedReplacementStartPublishesOldExitBeforeNewOccupantState() throws {
        let fixture = try Fixture()
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-old",
            startsNewOccupant: true
        )
        let baselineSequence = CmuxEventBus.shared.latestSequence

        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .idle,
            sessionID: "session-new",
            startsNewOccupant: true
        )

        let payloads = fixture.agentEvents(after: baselineSequence)
            .compactMap { $0["payload"] as? [String: Any] }
        #expect(payloads.count == 2)
        #expect(payloads.compactMap { $0["state"] as? String } == ["exit", "idle"])
        #expect(payloads.compactMap { $0["session_id"] as? String } == ["session-old", "session-new"])
        #expect(payloads.compactMap { CmuxEventBus.int64($0["revision"]) } == [1, 2])
    }

    @Test
    func anonymousSessionStartRotatesOccupantGeneration() throws {
        let fixture = try Fixture()
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            startsNewOccupant: true
        )
        let original = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
        )

        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .needsInput
        )
        let updated = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
        )
        #expect(updated.revision == original.revision)

        let baselineSequence = CmuxEventBus.shared.latestSequence
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .idle,
            startsNewOccupant: true
        )

        let replacement = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
        )
        let payloads = fixture.agentEvents(after: baselineSequence)
            .compactMap { $0["payload"] as? [String: Any] }
        #expect(payloads.compactMap { $0["state"] as? String } == ["exit", "idle"])
        #expect(payloads.allSatisfy { $0["session_id"] is NSNull })
        #expect(replacement.revision > original.revision)
        #expect(!replacement.identifiesSameOccupant(as: original))
    }

    @Test
    func authoritativeSessionStartReplacesAnonymousOccupantAndSatisfiesPinnedExitWait() throws {
        let fixture = try Fixture()
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            startsNewOccupant: true
        )
        let original = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
        )
        let baselineSequence = CmuxEventBus.shared.latestSequence
        var didReplaceOccupant = false
        let coordinator = AgentWaitCoordinator(
            eventBus: .shared,
            shouldContinue: {
                if !didReplaceOccupant {
                    didReplaceOccupant = true
                    fixture.workspace.setAgentLifecycle(
                        key: "codex",
                        panelId: fixture.surfaceID,
                        lifecycle: .running,
                        sessionID: "session-known",
                        startsNewOccupant: true
                    )
                }
                return true
            }
        )

        let result = coordinator.wait(
            until: .exit,
            timeoutMilliseconds: 1_000,
            prepare: {
                AgentWaitCoordinator.Preparation(
                    afterSequence: CmuxEventBus.shared.latestSequence,
                    surface: fixture.workspace.agentWaitSurfaceSnapshot(
                        surfaceID: fixture.surfaceID
                    )
                )
            }
        )

        let value = try result.get()
        let replacement = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
        )
        let payloads = fixture.agentEvents(after: baselineSequence)
            .compactMap { $0["payload"] as? [String: Any] }
        #expect(value.status == .satisfied)
        #expect(value.state == .exit)
        #expect(value.sessionID == nil)
        #expect(payloads.compactMap { $0["state"] as? String } == ["exit", "running"])
        #expect(payloads.first?["session_id"] is NSNull)
        #expect(payloads.last?["session_id"] as? String == "session-known")
        #expect(replacement.revision > original.revision)
        #expect(!replacement.identifiesSameOccupant(as: original))
    }

    @Test
    func duplicateAuthoritativeSessionStartPreservesOccupantGeneration() throws {
        let fixture = try Fixture()
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-known",
            startsNewOccupant: true
        )
        let original = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
        )
        let baselineSequence = CmuxEventBus.shared.latestSequence

        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-known",
            startsNewOccupant: true
        )

        let duplicate = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
        )
        #expect(duplicate.revision == original.revision)
        #expect(duplicate.identifiesSameOccupant(as: original))
        #expect(fixture.agentEvents(after: baselineSequence).isEmpty)
    }

    @Test
    func sessionIdentityEnrichmentSatisfiesWaitPinnedToAnonymousRevision() throws {
        let fixture = try Fixture()
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            startsNewOccupant: true
        )
        let original = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
        )
        var didEnrich = false
        let coordinator = AgentWaitCoordinator(
            eventBus: .shared,
            shouldContinue: {
                if !didEnrich {
                    didEnrich = true
                    fixture.workspace.setAgentLifecycle(
                        key: "codex",
                        panelId: fixture.surfaceID,
                        lifecycle: .idle,
                        sessionID: "session-known"
                    )
                }
                return true
            }
        )

        let result = coordinator.wait(
            until: .idle,
            timeoutMilliseconds: 1_000,
            prepare: {
                AgentWaitCoordinator.Preparation(
                    afterSequence: CmuxEventBus.shared.latestSequence,
                    surface: fixture.workspace.agentWaitSurfaceSnapshot(
                        surfaceID: fixture.surfaceID
                    )
                )
            }
        )

        let value = try result.get()
        let enriched = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
        )
        #expect(value.status == .satisfied)
        #expect(value.state == .idle)
        #expect(value.sessionID == nil)
        #expect(enriched.sessionID == "session-known")
        #expect(enriched.revision == original.revision)
        #expect(enriched.identifiesSameOccupant(as: original))
    }

    @Test
    func staleAuthoritativeUpdateCannotReplaceCurrentOccupant() throws {
        let fixture = try Fixture()
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-old",
            startsNewOccupant: true
        )
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-current",
            startsNewOccupant: true
        )
        let current = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
        )
        let baselineSequence = CmuxEventBus.shared.latestSequence

        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .idle,
            sessionID: "session-old"
        )

        let retained = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
        )
        #expect(retained == current)
        #expect(fixture.agentEvents(after: baselineSequence).isEmpty)
    }

    @Test
    func ambiguousAgentRecordsDoNotSelectAWaitOccupant() throws {
        let fixture = try Fixture()
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "codex-session",
            startsNewOccupant: true
        )
        fixture.workspace.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "claude-session",
            startsNewOccupant: true
        )

        let snapshot = try #require(
            fixture.workspace.agentWaitSurfaceSnapshot(surfaceID: fixture.surfaceID)
        )
        #expect(snapshot.occupant == nil)
    }

    @Test
    func socketNewOccupantFlagRotatesAnonymousGeneration() throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
            TerminalMutationBus.shared.drainForTesting()
        }
        let workspace = try #require(manager.selectedWorkspace)
        let surfaceID = try #require(workspace.focusedPanelId)
        let target = "--tab=\(workspace.id.uuidString) --panel=\(surfaceID.uuidString)"

        let firstResponse = TerminalController.shared.handleSocketLine(
            "set_agent_lifecycle codex running \(target) --new-occupant"
        )
        #expect(firstResponse == "OK")
        TerminalMutationBus.shared.drainForTesting()
        let original = try #require(
            workspace.agentLifecycleRecordsByPanelId[surfaceID]?["codex"]
        )

        let replacementResponse = TerminalController.shared.handleSocketLine(
            "set_agent_lifecycle codex idle \(target) --new-occupant"
        )
        #expect(replacementResponse == "OK")
        TerminalMutationBus.shared.drainForTesting()
        let replacement = try #require(
            workspace.agentLifecycleRecordsByPanelId[surfaceID]?["codex"]
        )

        #expect(original.sessionID == nil)
        #expect(replacement.sessionID == nil)
        #expect(replacement.revision > original.revision)
        #expect(!replacement.identifiesSameOccupant(as: original))
    }

    @Test
    func staleAnonymousLifecycleCommandCannotMutateReplacementPIDOwner() throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
            TerminalMutationBus.shared.drainForTesting()
        }
        let workspace = try #require(manager.selectedWorkspace)
        let surfaceID = try #require(workspace.focusedPanelId)
        let target = "--tab=\(workspace.id.uuidString) --panel=\(surfaceID.uuidString)"
        let pidKey = "kiro.\(surfaceID.uuidString)"

        for pid in [41_001, 41_002] {
            #expect(
                TerminalController.shared.handleSocketLine(
                    "set_agent_pid \(pidKey) \(pid) \(target)"
                ) == "OK"
            )
            #expect(
                TerminalController.shared.handleSocketLine(
                    "set_agent_lifecycle kiro running \(target) --new-occupant " +
                    "--expected-pid-key=\(pidKey) --expected-pid=\(pid)"
                ) == "OK"
            )
            TerminalMutationBus.shared.drainForTesting()
        }
        let replacement = try #require(
            workspace.agentLifecycleRecordsByPanelId[surfaceID]?["kiro"]
        )

        #expect(
            TerminalController.shared.handleSocketLine(
                "set_agent_lifecycle kiro idle \(target) " +
                "--expected-pid-key=\(pidKey) --expected-pid=41001"
            ) == "OK"
        )
        TerminalMutationBus.shared.drainForTesting()

        #expect(
            workspace.agentLifecycleRecordsByPanelId[surfaceID]?["kiro"] == replacement
        )
    }

    @Test
    func staleExplicitPIDClaimCannotEraseReplacementLifecycle() throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
            TerminalMutationBus.shared.drainForTesting()
        }
        let workspace = try #require(manager.selectedWorkspace)
        let surfaceID = try #require(workspace.focusedPanelId)
        let target = "--tab=\(workspace.id.uuidString) --panel=\(surfaceID.uuidString)"
        workspace.recordAgentPID(
            key: "codex.session-new",
            pid: getpid(),
            panelId: surfaceID,
            refreshPorts: false
        )
        workspace.setAgentLifecycle(
            key: "codex",
            panelId: surfaceID,
            lifecycle: .running,
            sessionID: "session-new",
            startsNewOccupant: true
        )
        let replacement = try #require(
            workspace.agentLifecycleRecordsByPanelId[surfaceID]?["codex"]
        )
        let baselineSequence = CmuxEventBus.shared.latestSequence

        #expect(
            TerminalController.shared.handleSocketLine(
                "set_agent_pid codex.session-old \(getpid()) \(target) --session-id=session-old"
            ) == "OK"
        )
        TerminalMutationBus.shared.drainForTesting()

        #expect(
            workspace.agentLifecycleRecordsByPanelId[surfaceID]?["codex"] == replacement
        )
        #expect(workspace.agentPIDs["codex.session-new"] == getpid())
        #expect(workspace.agentPIDs["codex.session-old"] == nil)
        #expect(CmuxEventBus.shared.latestSequence == baselineSequence)
    }

    @Test
    func staleResumeBindingRevisionOrAgentGuardCannotClearReplacement() throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }
        let workspace = try #require(manager.selectedWorkspace)
        let surfaceID = try #require(workspace.focusedPanelId)
        let sharedSessionID = surfaceID.uuidString
        workspace.setAgentLifecycle(
            key: "kiro",
            panelId: surfaceID,
            lifecycle: .running,
            sessionID: "session-current",
            startsNewOccupant: true
        )
        let original = SurfaceResumeBindingSnapshot(
            name: "Kiro",
            kind: "kiro",
            command: "kiro --resume",
            checkpointId: sharedSessionID,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 100
        )
        let replacement = SurfaceResumeBindingSnapshot(
            name: "Kiro",
            kind: "kiro",
            command: "kiro --resume",
            checkpointId: sharedSessionID,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 200
        )
        #expect(
            workspace.setSurfaceResumeBinding(
                original,
                panelId: surfaceID
            )
        )
        #expect(
            workspace.setSurfaceResumeBinding(
                replacement,
                panelId: surfaceID
            )
        )

        let request: [String: Any] = [
            "id": "stale-resume-binding-clear",
            "method": "surface.resume.clear",
            "params": [
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceID.uuidString,
                "checkpoint_id": sharedSessionID,
                "source": "agent-hook",
                "agent_session_ended": true,
                "_cmux_expected_updated_at": original.updatedAt,
                "_cmux_agent_mutation_guard": ControlSidebarAgentMutationGuard.session(
                    statusKey: "kiro",
                    sessionID: "session-stale"
                ).socketEnvelope,
            ],
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try #require(String(data: requestData, encoding: .utf8))
        let responseLine = TerminalController.shared.handleSocketLine(requestLine)
        let responseData = try #require(responseLine.data(using: .utf8))
        let envelope = try #require(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        let result = try #require(envelope["result"] as? [String: Any])

        #expect(envelope["ok"] as? Bool == true)
        #expect(result["cleared"] as? Bool == false)
        #expect(
            workspace.surfaceResumeBinding(panelId: surfaceID)
                == replacement
        )

        let matchingRequest: [String: Any] = [
            "id": "matching-resume-binding-clear",
            "method": "surface.resume.clear",
            "params": [
                "workspace_id": workspace.id.uuidString,
                "surface_id": surfaceID.uuidString,
                "checkpoint_id": sharedSessionID,
                "source": "agent-hook",
                "agent_session_ended": true,
                "_cmux_expected_updated_at": replacement.updatedAt,
                "_cmux_agent_mutation_guard": ControlSidebarAgentMutationGuard.session(
                    statusKey: "kiro",
                    sessionID: "session-current"
                ).socketEnvelope,
            ],
        ]
        let matchingRequestData = try JSONSerialization.data(withJSONObject: matchingRequest)
        let matchingRequestLine = try #require(
            String(data: matchingRequestData, encoding: .utf8)
        )
        let matchingResponseLine = TerminalController.shared.handleSocketLine(
            matchingRequestLine
        )
        let matchingResponseData = try #require(
            matchingResponseLine.data(using: .utf8)
        )
        let matchingEnvelope = try #require(
            JSONSerialization.jsonObject(with: matchingResponseData) as? [String: Any]
        )
        let matchingResult = try #require(
            matchingEnvelope["result"] as? [String: Any]
        )
        #expect(matchingEnvelope["ok"] as? Bool == true)
        #expect(matchingResult["cleared"] as? Bool == true)
        #expect(workspace.surfaceResumeBinding(panelId: surfaceID) == nil)
    }

    @Test
    func staleAnonymousPIDTokenCannotClearReplacementRuntime() throws {
        let fixture = try Fixture()
        let pidKey = "kiro.\(fixture.surfaceID.uuidString)"
        let originalPID = getpid()
        let replacementPID = getppid()
        fixture.workspace.recordAgentPID(
            key: pidKey,
            pid: originalPID,
            panelId: fixture.surfaceID,
            refreshPorts: false
        )
        let originalIdentity = try #require(
            fixture.workspace.agentPIDProcessIdentitiesByKey[pidKey]
        )
        fixture.workspace.setAgentLifecycle(
            key: "kiro",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            startsNewOccupant: true
        )
        fixture.workspace.recordAgentPID(
            key: pidKey,
            pid: replacementPID,
            panelId: fixture.surfaceID,
            refreshPorts: false
        )
        fixture.workspace.setAgentLifecycle(
            key: "kiro",
            panelId: fixture.surfaceID,
            lifecycle: .idle,
            startsNewOccupant: true
        )
        let replacement = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["kiro"]
        )

        let didClear = fixture.workspace.clearAgentPID(
            key: pidKey,
            panelId: fixture.surfaceID,
            clearStatus: true,
            refreshPorts: false,
            expectedPID: originalPID,
            expectedPIDStartSeconds: originalIdentity.startSeconds,
            expectedPIDStartMicroseconds: originalIdentity.startMicroseconds
        )

        #expect(!didClear)
        #expect(fixture.workspace.agentPIDs[pidKey] == replacementPID)
        #expect(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["kiro"]
                == replacement
        )
    }

    @Test
    func generationVerifiedLifecycleReclaimsMissingAnonymousPIDOwnership() throws {
        let fixture = try Fixture()
        let pidKey = "kiro.\(fixture.surfaceID.uuidString)"
        let pid = getpid()
        let identity = try #require(AgentPIDProcessIdentity(pid: pid))

        fixture.workspace.setAgentLifecycle(
            key: "kiro",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            expectedPIDKey: pidKey,
            expectedPID: pid,
            expectedPIDStartSeconds: identity.startSeconds,
            expectedPIDStartMicroseconds: identity.startMicroseconds
        )

        #expect(fixture.workspace.agentPIDs[pidKey] == pid)
        #expect(fixture.workspace.agentPIDPanelIdsByKey[pidKey] == fixture.surfaceID)
        #expect(fixture.workspace.agentPIDProcessIdentitiesByKey[pidKey] == identity)
        #expect(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["kiro"]?.state
                == .running
        )
    }

    @Test
    func generationMismatchedLifecycleCannotReclaimAnonymousPIDOwnership() throws {
        let fixture = try Fixture()
        let pidKey = "kiro.\(fixture.surfaceID.uuidString)"
        let pid = getpid()
        let identity = try #require(AgentPIDProcessIdentity(pid: pid))

        fixture.workspace.setAgentLifecycle(
            key: "kiro",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            expectedPIDKey: pidKey,
            expectedPID: pid,
            expectedPIDStartSeconds: identity.startSeconds + 1,
            expectedPIDStartMicroseconds: identity.startMicroseconds
        )

        #expect(fixture.workspace.agentPIDs[pidKey] == nil)
        #expect(fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["kiro"] == nil)
    }

    @Test
    func newerAnonymousProcessGenerationReplacesOlderWorkspaceOccupant() throws {
        let fixture = try Fixture()
        let olderProcess = try sleepingProcess()
        let newerProcess = try sleepingProcess()
        defer { terminate([olderProcess, newerProcess]) }
        let olderIdentity = try #require(
            AgentPIDProcessIdentity(pid: olderProcess.processIdentifier)
        )
        let newerIdentity = try #require(
            AgentPIDProcessIdentity(pid: newerProcess.processIdentifier)
        )
        try #require(olderIdentity.startedBefore(newerIdentity))
        let olderKey = "kiro.older"
        let newerKey = "kiro.newer"

        fixture.workspace.setAgentLifecycle(
            key: "kiro",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            expectedPIDKey: olderKey,
            expectedPID: olderProcess.processIdentifier,
            expectedPIDStartSeconds: olderIdentity.startSeconds,
            expectedPIDStartMicroseconds: olderIdentity.startMicroseconds
        )
        let olderRecord = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["kiro"]
        )

        fixture.workspace.setAgentLifecycle(
            key: "kiro",
            panelId: fixture.surfaceID,
            lifecycle: .idle,
            expectedPIDKey: newerKey,
            expectedPID: newerProcess.processIdentifier,
            expectedPIDStartSeconds: newerIdentity.startSeconds,
            expectedPIDStartMicroseconds: newerIdentity.startMicroseconds
        )
        let replacementRecord = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["kiro"]
        )

        #expect(fixture.workspace.agentPIDs[olderKey] == nil)
        #expect(fixture.workspace.agentPIDs[newerKey] == newerProcess.processIdentifier)
        #expect(replacementRecord.revision > olderRecord.revision)
        #expect(replacementRecord.state == .idle)

        fixture.workspace.setAgentLifecycle(
            key: "kiro",
            panelId: fixture.surfaceID,
            lifecycle: .needsInput,
            expectedPIDKey: olderKey,
            expectedPID: olderProcess.processIdentifier,
            expectedPIDStartSeconds: olderIdentity.startSeconds,
            expectedPIDStartMicroseconds: olderIdentity.startMicroseconds
        )

        #expect(fixture.workspace.agentPIDs[olderKey] == nil)
        #expect(fixture.workspace.agentPIDs[newerKey] == newerProcess.processIdentifier)
        #expect(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["kiro"]
                == replacementRecord
        )
    }

    @Test
    func newerAnonymousProcessGenerationMovesDockOwnershipAndRejectsStaleReclaim() throws {
        let firstSource = Workspace()
        let secondSource = Workspace()
        let firstPanelID = try #require(firstSource.focusedPanelId)
        let secondPanelID = try #require(secondSource.focusedPanelId)
        let firstTransfer = try #require(firstSource.detachSurface(panelId: firstPanelID))
        let secondTransfer = try #require(secondSource.detachSurface(panelId: secondPanelID))
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer { dock.closeAllPanels() }
        let rootPaneID = try #require(dock.bonsplitController.allPaneIds.first)
        try #require(dock.attachDetachedSurface(firstTransfer, inPane: rootPaneID, focus: false))
        try #require(
            dock.attachDetachedSurface(
                secondTransfer,
                bySplitting: rootPaneID,
                orientation: .horizontal,
                insertFirst: false,
                focus: false
            )
        )

        let olderProcess = try sleepingProcess()
        let newerProcess = try sleepingProcess()
        defer { terminate([olderProcess, newerProcess]) }
        let olderIdentity = try #require(
            AgentPIDProcessIdentity(pid: olderProcess.processIdentifier)
        )
        let newerIdentity = try #require(
            AgentPIDProcessIdentity(pid: newerProcess.processIdentifier)
        )
        try #require(olderIdentity.startedBefore(newerIdentity))
        let pidKey = "kiro.shared"

        _ = dock.recordAgentPID(
            key: pidKey,
            pid: olderProcess.processIdentifier,
            panelId: firstPanelID,
            expectedPIDStartSeconds: olderIdentity.startSeconds,
            expectedPIDStartMicroseconds: olderIdentity.startMicroseconds
        )
        _ = dock.recordAgentPID(
            key: pidKey,
            pid: newerProcess.processIdentifier,
            panelId: secondPanelID,
            expectedPIDStartSeconds: newerIdentity.startSeconds,
            expectedPIDStartMicroseconds: newerIdentity.startMicroseconds
        )

        #expect(dock.agentRuntimeByPanelId[firstPanelID]?.agentPIDKeys.contains(pidKey) != true)
        #expect(
            dock.agentRuntimeByPanelId[secondPanelID]?.agentPIDs[pidKey]
                == newerProcess.processIdentifier
        )

        _ = dock.recordAgentPID(
            key: pidKey,
            pid: olderProcess.processIdentifier,
            panelId: firstPanelID,
            expectedPIDStartSeconds: olderIdentity.startSeconds,
            expectedPIDStartMicroseconds: olderIdentity.startMicroseconds
        )

        #expect(dock.agentRuntimeByPanelId[firstPanelID]?.agentPIDKeys.contains(pidKey) != true)
        #expect(
            dock.agentRuntimeByPanelId[secondPanelID]?.agentPIDs[pidKey]
                == newerProcess.processIdentifier
        )
    }

    @Test
    func dockSessionAuthorizationUsesExactStructuredIdentity() throws {
        let source = Workspace()
        let panelID = try #require(source.focusedPanelId)
        let transfer = try #require(source.detachSurface(panelId: panelID))
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer { dock.closeAllPanels() }
        let paneID = try #require(dock.bonsplitController.allPaneIds.first)
        try #require(dock.attachDetachedSurface(transfer, inPane: paneID, focus: false))
        let currentSessionID = "bar.foo"
        let pidKey = "codex.\(currentSessionID)"

        _ = dock.recordAgentPID(key: pidKey, pid: getpid(), panelId: panelID)
        dock.setAgentLifecycle(
            key: "codex",
            panelId: panelID,
            lifecycle: .running,
            sessionID: currentSessionID,
            startsNewOccupant: true
        )

        let owner = ControlSidebarPanelOwner.dock(dock)
        #expect(
            owner.acceptsAgentMutationGuard(
                .session(statusKey: "codex", sessionID: currentSessionID),
                panelId: panelID
            )
        )
        #expect(
            !owner.acceptsAgentMutationGuard(
                .session(statusKey: "codex", sessionID: "foo"),
                panelId: panelID
            )
        )

        dock.setAgentLifecycle(
            key: "codex",
            panelId: panelID,
            lifecycle: .needsInput,
            sessionID: "foo"
        )
        #expect(dock.agentRuntimeByPanelId[panelID]?.agentLifecycleStates["codex"] == .running)
        #expect(
            dock.agentRuntimeByPanelId[panelID]?.agentLifecycleSessionIDs["codex"]
                == currentSessionID
        )
    }

    @Test
    func dockPreservesRecordedProcessAuthorizationAfterExit() throws {
        let source = Workspace()
        let panelID = try #require(source.focusedPanelId)
        let transfer = try #require(source.detachSurface(panelId: panelID))
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer { dock.closeAllPanels() }
        let paneID = try #require(dock.bonsplitController.allPaneIds.first)
        try #require(dock.attachDetachedSurface(transfer, inPane: paneID, focus: false))
        let process = try sleepingProcess()
        let identity = try #require(AgentPIDProcessIdentity(pid: process.processIdentifier))
        let pidKey = "kiro.current"

        dock.setAgentLifecycle(
            key: "kiro",
            panelId: panelID,
            lifecycle: .running,
            expectedPIDKey: pidKey,
            expectedPID: process.processIdentifier,
            expectedPIDStartSeconds: identity.startSeconds,
            expectedPIDStartMicroseconds: identity.startMicroseconds
        )
        process.terminate()
        process.waitUntilExit()
        dock.setAgentLifecycle(
            key: "kiro",
            panelId: panelID,
            lifecycle: .idle,
            expectedPIDKey: pidKey,
            expectedPID: process.processIdentifier,
            expectedPIDStartSeconds: identity.startSeconds,
            expectedPIDStartMicroseconds: identity.startMicroseconds
        )

        #expect(dock.agentRuntimeByPanelId[panelID]?.agentLifecycleStates["kiro"] == .idle)
        #expect(
            ControlSidebarPanelOwner.dock(dock).acceptsAgentMutationGuard(
                .process(
                    statusKey: "kiro",
                    pidKey: pidKey,
                    pid: process.processIdentifier,
                    startSeconds: identity.startSeconds,
                    startMicroseconds: identity.startMicroseconds
                ),
                panelId: panelID
            )
        )
    }

    @Test
    func dockStructuredPIDReplacementPublishesOneExitBeforeReplacement() throws {
        let source = Workspace()
        let panelID = try #require(source.focusedPanelId)
        let transfer = try #require(source.detachSurface(panelId: panelID))
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer { dock.closeAllPanels() }
        let paneID = try #require(dock.bonsplitController.allPaneIds.first)
        try #require(dock.attachDetachedSurface(transfer, inPane: paneID, focus: false))

        let olderProcess = try sleepingProcess()
        let newerProcess = try sleepingProcess()
        defer { terminate([olderProcess, newerProcess]) }
        let olderIdentity = try #require(
            AgentPIDProcessIdentity(pid: olderProcess.processIdentifier)
        )
        let newerIdentity = try #require(
            AgentPIDProcessIdentity(pid: newerProcess.processIdentifier)
        )
        try #require(olderIdentity.startedBefore(newerIdentity))

        #expect(dock.setAgentLifecycle(
            key: "codex",
            panelId: panelID,
            lifecycle: .running,
            expectedPIDKey: "codex.older",
            expectedPID: olderProcess.processIdentifier,
            expectedPIDStartSeconds: olderIdentity.startSeconds,
            expectedPIDStartMicroseconds: olderIdentity.startMicroseconds,
            startsNewOccupant: true
        ))
        let baseline = CmuxEventBus.shared.latestSequence

        #expect(dock.setAgentLifecycle(
            key: "codex",
            panelId: panelID,
            lifecycle: .running,
            expectedPIDKey: "codex.newer",
            expectedPID: newerProcess.processIdentifier,
            expectedPIDStartSeconds: newerIdentity.startSeconds,
            expectedPIDStartMicroseconds: newerIdentity.startMicroseconds,
            startsNewOccupant: true
        ))

        let states = CmuxEventBus.shared.retainedSnapshot()
            .filter { event in
                event["name"] as? String == "agent.state.changed"
                    && event["surface_id"] as? String == panelID.uuidString
                    && (CmuxEventBus.int64(event["seq"]) ?? 0) > baseline
            }
            .compactMap { ($0["payload"] as? [String: Any])?["state"] as? String }
        #expect(states == ["exit", "running"])
    }

    @Test
    func staleSessionTeardownCannotClearReplacementLifecycle() throws {
        let fixture = try Fixture()
        fixture.workspace.recordAgentPID(
            key: "codex.session-old",
            pid: getpid(),
            panelId: fixture.surfaceID,
            refreshPorts: false
        )
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-old"
        )
        fixture.workspace.recordAgentPID(
            key: "codex.session-new",
            pid: getpid(),
            panelId: fixture.surfaceID,
            refreshPorts: false
        )
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .idle,
            sessionID: "session-new",
            startsNewOccupant: true
        )
        let baselineSequence = CmuxEventBus.shared.latestSequence

        let didClear = fixture.workspace.clearAgentPID(
            key: "codex.session-old",
            panelId: fixture.surfaceID,
            clearStatus: true,
            refreshPorts: false,
            expectedLifecycleSessionID: "session-old"
        )

        #expect(!didClear)
        #expect(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]?.sessionID
                == "session-new"
        )
        #expect(
            fixture.workspace.agentLifecycleStatesByPanelId[fixture.surfaceID]?["codex"] == .idle
        )
        #expect(fixture.agentEvents(after: baselineSequence).isEmpty)
    }

    @Test
    func dockDwellDoesNotRestoreCachedLifecycleAsAuthoritative() throws {
        let fixture = try Fixture()
        let lifecycleKey = "claude_code"
        fixture.workspace.setAgentLifecycle(
            key: lifecycleKey,
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-before-dock",
            startsNewOccupant: true
        )
        fixture.workspace.recordAgentPID(
            key: lifecycleKey,
            pid: getpid(),
            panelId: fixture.surfaceID,
            refreshPorts: false
        )
        let intoDock = try #require(
            fixture.workspace.detachSurface(panelId: fixture.surfaceID)
        )
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { dock.closeAllPanels() }
        let dockPaneID = try #require(dock.bonsplitController.allPaneIds.first)
        try #require(
            dock.attachDetachedSurface(intoDock, inPane: dockPaneID, focus: false)
        )

        // The Dock has no structured lifecycle refresh path. A live PID keeps
        // runtime routing alive, but must not make the entry-time lifecycle
        // record authoritative after an arbitrary Dock dwell.
        let outOfDock = try #require(
            dock.detachSurface(panelId: fixture.surfaceID)
        )
        let destination = Workspace()
        defer { destination.teardownAllPanels() }
        let destinationPaneID = try #require(
            destination.bonsplitController.allPaneIds.first
        )
        try #require(
            destination.attachDetachedSurface(
                outOfDock,
                inPane: destinationPaneID,
                focus: false
            )
        )

        let snapshot = try #require(
            destination.agentWaitSurfaceSnapshot(surfaceID: fixture.surfaceID)
        )
        #expect(destination.agentPIDs[lifecycleKey] == getpid())
        #expect(snapshot.occupant == nil)
    }

    @Test
    func staleClaudeTeardownCannotClearAtomicReplacementOccupantClaim() throws {
        let fixture = try Fixture()
        let sharedPIDKey = "claude_code"
        let originalPID = getppid()
        let replacementPID = getpid()
        fixture.workspace.recordAgentPID(
            key: sharedPIDKey,
            pid: originalPID,
            panelId: fixture.surfaceID,
            refreshPorts: false
        )
        fixture.workspace.setAgentLifecycle(
            key: sharedPIDKey,
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-old",
            startsNewOccupant: true
        )

        // A replacement SessionStart claims lifecycle and shared PID routing
        // in one model mutation, so stale teardown can observe either the old
        // owner or the replacement, never a replacement PID owned by the old
        // lifecycle session.
        fixture.workspace.setAgentLifecycle(
            key: sharedPIDKey,
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-new",
            startsNewOccupant: true,
            expectedPIDKey: sharedPIDKey,
            expectedPID: replacementPID
        )
        let didClear = fixture.workspace.clearAgentPID(
            key: sharedPIDKey,
            panelId: fixture.surfaceID,
            clearStatus: true,
            refreshPorts: false,
            expectedLifecycleSessionID: "session-old",
            expectedPID: originalPID
        )

        #expect(!didClear)
        #expect(fixture.workspace.agentPIDs[sharedPIDKey] == replacementPID)
        #expect(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?[sharedPIDKey]?
                .sessionID == "session-new"
        )
    }

    @Test
    func liveDetachAndReattachPreservesLifecycleWithoutExit() throws {
        let fixture = try Fixture()
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-live"
        )
        let original = try #require(
            fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
        )
        let baselineSequence = CmuxEventBus.shared.latestSequence

        let detached = try #require(
            fixture.workspace.detachSurface(panelId: fixture.surfaceID)
        )

        #expect(detached.agentLifecycleRecords["codex"] == original)
        #expect(fixture.workspace.agentLifecycleRecordsByPanelId[fixture.surfaceID] == nil)
        #expect(fixture.agentEvents(after: baselineSequence).isEmpty)

        let destination = Workspace()
        let destinationPane = try #require(
            destination.bonsplitController.allPaneIds.first
        )
        let attachedPanelID = destination.attachDetachedSurface(
            detached,
            inPane: destinationPane,
            focus: false
        )

        #expect(attachedPanelID == fixture.surfaceID)
        #expect(
            destination.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["codex"]
                == original
        )
        #expect(fixture.agentEvents(after: baselineSequence).isEmpty)
    }

    @Test
    func liveDetachTransfersOnlyAgentRecordsAndRehomesManualStateInSource() throws {
        let fixture = try Fixture()
        let paneID = try #require(fixture.workspace.bonsplitController.allPaneIds.first)
        let sourceSurvivor = try #require(
            fixture.workspace.newTerminalSurface(inPane: paneID, focus: false)
        )
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-live"
        )
        fixture.workspace.setAgentLifecycle(
            key: "manual:build",
            panelId: fixture.surfaceID,
            lifecycle: .running
        )

        let detached = try #require(
            fixture.workspace.detachSurface(panelId: fixture.surfaceID)
        )

        #expect(detached.agentLifecycleRecords["codex"]?.sessionID == "session-live")
        #expect(detached.agentLifecycleRecords["manual:build"] == nil)
        #expect(
            fixture.workspace.agentLifecycleRecordsByPanelId[sourceSurvivor.id]?["manual:build"]?.state
                == .running
        )

        let destination = Workspace()
        let destinationPane = try #require(
            destination.bonsplitController.allPaneIds.first
        )
        _ = try #require(
            destination.attachDetachedSurface(
                detached,
                inPane: destinationPane,
                focus: false
            )
        )
        #expect(
            destination.agentLifecycleRecordsByPanelId[fixture.surfaceID]?["manual:build"]
                == nil
        )
    }

    @Test
    func surfaceTreeAliasResolvesToLifecycleOwningPanelAndWorkspace() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(
            key: "codex",
            panelId: panelID,
            lifecycle: .running,
            sessionID: "session-alias"
        )
        let surfaceTreeID = try #require(
            workspace.surfaceIdFromPanelId(panelID)?.uuid
        )

        let snapshot = try #require(
            workspace.agentWaitSurfaceSnapshot(surfaceID: surfaceTreeID)
        )
        let resolvedWorkspace = try #require(
            TerminalController.shared.v2ResolveWorkspace(
                params: ["surface_id": surfaceTreeID.uuidString],
                tabManager: manager
            )
        )

        #expect(snapshot.surfaceID == panelID)
        #expect(snapshot.occupant?.sessionID == "session-alias")
        #expect(resolvedWorkspace === workspace)
    }

    @Test
    func dockSurfaceSnapshotUsesTransferredLifecycleOwner() throws {
        let fixture = try Fixture()
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .idle,
            sessionID: "session-dock"
        )
        let detached = try #require(
            fixture.workspace.detachSurface(panelId: fixture.surfaceID)
        )
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { dock.closeAllPanels() }
        let paneID = try #require(dock.bonsplitController.allPaneIds.first)
        try #require(
            dock.attachDetachedSurface(detached, inPane: paneID, focus: false)
        )

        let snapshot = try #require(
            dock.agentWaitSurfaceSnapshot(panelID: fixture.surfaceID)
        )

        #expect(snapshot.workspaceID == dock.workspaceId)
        #expect(snapshot.surfaceID == fixture.surfaceID)
        #expect(snapshot.paneID == paneID.id)
        #expect(snapshot.occupant?.sessionID == "session-dock")
        #expect(snapshot.occupant?.state == .idle)
    }

    @Test
    func closingDockPanelPublishesExitForTransferredLifecycleOwner() throws {
        let fixture = try Fixture()
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-transferred-close",
            startsNewOccupant: true
        )
        let detached = try #require(
            fixture.workspace.detachSurface(panelId: fixture.surfaceID)
        )
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { dock.closeAllPanels() }
        let paneID = try #require(dock.bonsplitController.allPaneIds.first)
        try #require(
            dock.attachDetachedSurface(detached, inPane: paneID, focus: false)
        )
        let sequence = CmuxEventBus.shared.latestSequence

        _ = dock.discardPanelStateAndClose(panelId: fixture.surfaceID)

        let exits = fixture.agentEvents(after: sequence)
            .compactMap { $0["payload"] as? [String: Any] }
            .filter { ($0["state"] as? String) == "exit" }
        #expect(exits.count == 1)
        #expect(exits.first?["session_id"] as? String == "session-transferred-close")
    }

    @Test
    func dockLifecycleReportsDriveWaitAndPublishExit() throws {
        let fixture = try Fixture()
        let pidKey = "codex.session-dock-live"
        fixture.workspace.recordAgentPID(
            key: pidKey,
            pid: getpid(),
            panelId: fixture.surfaceID,
            refreshPorts: false
        )
        fixture.workspace.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-dock-live",
            startsNewOccupant: true
        )
        let detached = try #require(
            fixture.workspace.detachSurface(panelId: fixture.surfaceID)
        )
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { dock.closeAllPanels() }
        let paneID = try #require(dock.bonsplitController.allPaneIds.first)
        try #require(
            dock.attachDetachedSurface(detached, inPane: paneID, focus: false)
        )

        dock.setAgentLifecycle(
            key: "codex",
            panelId: fixture.surfaceID,
            lifecycle: .running,
            sessionID: "session-dock-live"
        )
        let liveSnapshot = try #require(
            dock.agentWaitSurfaceSnapshot(panelID: fixture.surfaceID)
        )
        #expect(liveSnapshot.hasAuthoritativeLiveLifecycle)

        var didPublishIdle = false
        let coordinator = AgentWaitCoordinator(
            eventBus: .shared,
            shouldContinue: {
                if !didPublishIdle {
                    didPublishIdle = true
                    dock.setAgentLifecycle(
                        key: "codex",
                        panelId: fixture.surfaceID,
                        lifecycle: .idle,
                        sessionID: "session-dock-live"
                    )
                }
                return true
            }
        )
        let waitResult = coordinator.wait(
            until: .idle,
            timeoutMilliseconds: 1_000,
            prepare: {
                AgentWaitCoordinator.Preparation(
                    afterSequence: CmuxEventBus.shared.latestSequence,
                    surface: dock.agentWaitSurfaceSnapshot(
                        panelID: fixture.surfaceID
                    )
                )
            }
        )
        let value = try waitResult.get()
        #expect(value.status == .satisfied)
        #expect(value.state == .idle)
        #expect(value.workspaceID == dock.workspaceId)
        #expect(value.surfaceID == fixture.surfaceID)

        let exitBaseline = CmuxEventBus.shared.latestSequence
        #expect(dock.clearAgentPID(
            key: pidKey,
            panelId: fixture.surfaceID,
            clearStatus: true,
            expectedLifecycleSessionID: "session-dock-live"
        ))
        let exitPayloads = fixture.agentEvents(after: exitBaseline)
            .compactMap { $0["payload"] as? [String: Any] }
        #expect(exitPayloads.compactMap { $0["state"] as? String } == ["exit"])
        #expect(exitPayloads.first?["session_id"] as? String == "session-dock-live")
        #expect(
            dock.agentWaitSurfaceSnapshot(panelID: fixture.surfaceID)?.occupant == nil
        )
    }

    private struct Fixture {
        let workspace: Workspace
        let surfaceID: UUID

        @MainActor
        init() throws {
            workspace = Workspace()
            surfaceID = try #require(workspace.focusedPanelId)
        }

        func agentEvents(after sequence: Int64? = nil) -> [[String: Any]] {
            CmuxEventBus.shared.retainedSnapshot().filter { event in
                event["name"] as? String == "agent.state.changed"
                    && event["surface_id"] as? String == surfaceID.uuidString
                    && sequence.map {
                        (CmuxEventBus.int64(event["seq"]) ?? 0) > $0
                    } != false
            }
        }
    }

    private func sleepingProcess() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    private func terminate(_ processes: [Process]) {
        for process in processes where process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
