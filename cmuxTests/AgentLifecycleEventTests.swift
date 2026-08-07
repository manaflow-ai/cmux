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
    func staleResumeBindingRevisionCannotClearAnonymousReplacement() throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }
        let workspace = try #require(manager.selectedWorkspace)
        let surfaceID = try #require(workspace.focusedPanelId)
        let sharedSessionID = surfaceID.uuidString
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
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
