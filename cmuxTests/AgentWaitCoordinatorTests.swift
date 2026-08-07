import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct AgentWaitCoordinatorTests {
    @Test
    func stateReachedBeforeWaitStartsReturnsImmediately() throws {
        let fixture = Fixture(state: .idle)

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            until: .idle,
            timeoutMilliseconds: 0,
            prepare: { fixture.preparation(occupant: fixture.original) }
        )

        let value = try result.get()
        #expect(value.status == .satisfied)
        #expect(value.state == .idle)
        #expect(value.sessionID == fixture.original.sessionID)
    }

    @Test
    func stateReachedAfterPreparedSnapshotSequenceReplaysBeforeSubscription() throws {
        let fixture = Fixture(state: .running)

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            until: .idle,
            timeoutMilliseconds: 0,
            prepare: {
                fixture.preparation(occupant: fixture.original) {
                    fixture.publish(record: fixture.original, state: .idle, previous: .running)
                }
            }
        )

        let value = try result.get()
        #expect(value.status == .satisfied)
        #expect(value.state == .idle)
    }

    @Test
    func dockSnapshotRejectsWaitWithoutLiveLifecycleAuthority() {
        let fixture = Fixture(state: .running)
        let dockSnapshot = AgentWaitSurfaceSnapshot(
            workspaceID: UUID(),
            surfaceID: fixture.surfaceID,
            paneID: UUID(),
            occupant: fixture.original,
            hasAuthoritativeLiveLifecycle: false
        )

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            until: .idle,
            timeoutMilliseconds: nil,
            prepare: {
                AgentWaitCoordinator.Preparation(
                    afterSequence: fixture.bus.latestSequence,
                    surface: dockSnapshot
                )
            }
        )

        #expect(result == .failure(.liveLifecycleUnavailable))
    }

    @Test
    func routingRefreshUsesPreparedCanonicalSurfaceID() throws {
        let fixture = Fixture(state: .idle)
        var refreshedSurfaceID: UUID?

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            until: .idle,
            timeoutMilliseconds: nil,
            prepare: { fixture.preparation(occupant: fixture.original) },
            routingSnapshot: { surfaceID in
                refreshedSurfaceID = surfaceID
                return fixture.snapshot(occupant: fixture.original)
            }
        )

        #expect(try result.get().status == .satisfied)
        #expect(refreshedSurfaceID == fixture.surfaceID)
    }

    @Test
    func stateReachedWhileWaitingSatisfiesWait() throws {
        let fixture = Fixture(state: .running)
        var didPublish = false
        let coordinator = AgentWaitCoordinator(
            eventBus: fixture.bus,
            shouldContinue: {
                if !didPublish {
                    didPublish = true
                    fixture.publish(
                        record: fixture.original,
                        state: .idle,
                        previous: .running
                    )
                }
                return true
            }
        )

        let result = coordinator.wait(
            until: .idle,
            timeoutMilliseconds: 1_000,
            prepare: { fixture.preparation(occupant: fixture.original) }
        )

        let value = try result.get()
        #expect(value.status == .satisfied)
        #expect(value.state == .idle)
    }

    @Test
    func replacementOccupantCannotSatisfyPinnedWait() {
        let fixture = Fixture(state: .running)
        let replacement = AgentLifecycleRecord(
            agent: "codex",
            state: .idle,
            sessionID: "session-new",
            revision: fixture.original.revision + 1
        )

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            until: .idle,
            timeoutMilliseconds: 0,
            prepare: {
                fixture.preparation(occupant: fixture.original) {
                    fixture.publish(record: fixture.original, state: .exit, previous: .running)
                    fixture.publish(record: replacement, state: .idle, previous: nil)
                }
            }
        )

        #expect(result == .failure(.noAgent))
    }

    @Test
    func pinnedOccupantExitTerminatesWaitForNonExitState() {
        let fixture = Fixture(state: .running)
        let replacement = AgentLifecycleRecord(
            agent: "codex",
            state: .running,
            sessionID: "session-new",
            revision: fixture.original.revision + 1
        )
        var continuationChecks = 0
        let coordinator = AgentWaitCoordinator(
            eventBus: fixture.bus,
            shouldContinue: {
                continuationChecks += 1
                return continuationChecks <= 2
            }
        )

        let result = coordinator.wait(
            until: .idle,
            timeoutMilliseconds: nil,
            prepare: {
                fixture.preparation(occupant: fixture.original) {
                    fixture.publish(record: fixture.original, state: .exit, previous: .running)
                    fixture.publish(record: replacement, state: .running, previous: nil)
                }
            }
        )

        #expect(result == .failure(.noAgent))
        #expect(continuationChecks == 1)
    }

    @Test
    func zeroTimeoutReturnsTimedOutWithoutPollingState() throws {
        let fixture = Fixture(state: .running)

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            until: .idle,
            timeoutMilliseconds: 0,
            prepare: { fixture.preparation(occupant: fixture.original) }
        )

        let value = try result.get()
        #expect(value.status == .timedOut)
        #expect(value.state == .running)
    }

    @Test
    func timeoutUsesTheInjectedMonotonicDeadline() throws {
        let fixture = Fixture(state: .running)
        var now: TimeInterval = 10
        let coordinator = AgentWaitCoordinator(
            eventBus: fixture.bus,
            shouldContinue: {
                now += 0.251
                return true
            },
            monotonicNow: { now }
        )

        let result = coordinator.wait(
            until: .idle,
            timeoutMilliseconds: 250,
            prepare: { fixture.preparation(occupant: fixture.original) }
        )

        let value = try result.get()
        #expect(value.status == .timedOut)
        #expect(value.state == .running)
    }

    @Test
    func unrelatedEventsCannotStarveTimeout() throws {
        let fixture = Fixture(state: .running)

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            until: .idle,
            timeoutMilliseconds: 0,
            prepare: {
                fixture.preparation(occupant: fixture.original) {
                    fixture.bus.publish(
                        name: "surface.closed",
                        category: "surface",
                        source: "test",
                        surfaceId: UUID().uuidString
                    )
                }
            }
        )

        let value = try result.get()
        #expect(value.status == .timedOut)
        #expect(value.state == .running)
    }

    @Test
    func unrelatedSurfaceBurstCannotOverflowTargetWait() throws {
        let fixture = Fixture(state: .running, maxPendingEvents: 2)
        let publishUnrelatedEvent = {
            fixture.bus.publish(
                name: "agent.state.changed",
                category: "agent",
                source: "test",
                surfaceId: UUID().uuidString
            )
        }
        let coordinator = AgentWaitCoordinator(
            eventBus: fixture.bus,
            onSubscribe: { _ in
                publishUnrelatedEvent()
                fixture.publish(
                    record: fixture.original,
                    state: .idle,
                    previous: .running
                )
                for _ in 0..<16 {
                    publishUnrelatedEvent()
                }
            }
        )

        let result = coordinator.wait(
            until: .idle,
            timeoutMilliseconds: 0,
            prepare: { fixture.preparation(occupant: fixture.original) }
        )

        let value = try result.get()
        #expect(value.status == .satisfied)
        #expect(value.state == .idle)
    }

    @Test
    func needsInputTransitionSatisfiesWait() throws {
        let fixture = Fixture(state: .running)

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            until: .needsInput,
            timeoutMilliseconds: 0,
            prepare: {
                fixture.preparation(occupant: fixture.original) {
                    fixture.publish(
                        record: fixture.original,
                        state: .needsInput,
                        previous: .running
                    )
                }
            }
        )

        let value = try result.get()
        #expect(value.status == .satisfied)
        #expect(value.state == .needsInput)
    }

    @Test
    func replacementPublishesExitForPinnedOccupant() throws {
        let fixture = Fixture(state: .running)

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            until: .exit,
            timeoutMilliseconds: 0,
            prepare: {
                fixture.preparation(occupant: fixture.original) {
                    fixture.publish(record: fixture.original, state: .exit, previous: .running)
                }
            }
        )

        let value = try result.get()
        #expect(value.status == .satisfied)
        #expect(value.state == .exit)
    }

    @Test
    func revisionPinsOccupantWhenSessionIDIsUnavailable() throws {
        let fixture = Fixture(state: .running)
        let anonymousOccupant = AgentLifecycleRecord(
            agent: "codex",
            state: .running,
            sessionID: nil,
            revision: 41
        )
        let replacement = AgentLifecycleRecord(
            agent: "codex",
            state: .idle,
            sessionID: nil,
            revision: 42
        )

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            until: .idle,
            timeoutMilliseconds: 0,
            prepare: {
                fixture.preparation(occupant: anonymousOccupant) {
                    fixture.publish(record: replacement, state: .idle, previous: nil)
                }
            }
        )

        let value = try result.get()
        #expect(value.status == .timedOut)
        #expect(value.state == .running)
        #expect(value.sessionID == nil)
    }

    @Test
    func sessionIdentityEnrichmentKeepsTheRevisionPinnedOccupant() {
        let known = AgentLifecycleRecord(
            agent: "codex",
            state: .running,
            sessionID: "session-known",
            revision: 41
        )
        let unknown = AgentLifecycleRecord(
            agent: "codex",
            state: .running,
            sessionID: nil,
            revision: 41
        )

        #expect(known.identifiesSameOccupant(as: unknown))
        #expect(unknown.identifiesSameOccupant(as: known))
    }

    @Test
    func subscriptionCloseReasonIsNotPartOfWaitError() {
        let fixture = Fixture(state: .running)
        let coordinator = AgentWaitCoordinator(
            eventBus: fixture.bus,
            onSubscribe: { $0.close(reason: "internal buffer details") }
        )

        let result = coordinator.wait(
            until: .idle,
            timeoutMilliseconds: nil,
            prepare: { fixture.preparation(occupant: fixture.original) }
        )

        #expect(result == .failure(.subscriptionClosed))
    }

    @Test
    func surfaceClosureHasDistinctTerminalStatus() throws {
        let fixture = Fixture(state: .running)

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            until: .idle,
            timeoutMilliseconds: 0,
            prepare: {
                fixture.preparation(occupant: fixture.original) {
                    fixture.bus.publish(
                        name: "surface.closed",
                        category: "surface",
                        source: "test",
                        workspaceId: fixture.workspaceID.uuidString,
                        surfaceId: fixture.surfaceID.uuidString,
                        paneId: fixture.paneID.uuidString
                    )
                }
            }
        )

        let value = try result.get()
        #expect(value.status == .surfaceClosed)
        #expect(value.state == .running)
    }

    @Test
    func transferClosureKeepsWaitingForTheStableSurfaceOccupant() throws {
        let fixture = Fixture(state: .running)
        let destinationWorkspaceID = UUID()
        let destinationPaneID = UUID()

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            until: .idle,
            timeoutMilliseconds: 1_000,
            prepare: {
                fixture.preparation(occupant: fixture.original) {
                    fixture.bus.publish(
                        name: "surface.closed",
                        category: "surface",
                        source: "workspace.lifecycle",
                        workspaceId: fixture.workspaceID.uuidString,
                        surfaceId: fixture.surfaceID.uuidString,
                        paneId: fixture.paneID.uuidString,
                        payload: ["origin": "detach"]
                    )
                    fixture.bus.publishAgentStateChanged(
                        workspaceID: destinationWorkspaceID,
                        surfaceID: fixture.surfaceID,
                        paneID: destinationPaneID,
                        record: fixture.original,
                        state: .idle,
                        previousState: .running
                    )
                }
            }
        )

        let value = try result.get()
        #expect(value.status == .satisfied)
        #expect(value.state == .idle)
        #expect(value.workspaceID == destinationWorkspaceID)
        #expect(value.surfaceID == fixture.surfaceID)
        #expect(value.paneID == destinationPaneID)
    }

    @Test
    func transferTimeoutRefreshesRoutingWithoutLifecycleTransition() throws {
        let fixture = Fixture(state: .running)
        let destination = AgentWaitSurfaceSnapshot(
            workspaceID: UUID(),
            surfaceID: fixture.surfaceID,
            paneID: UUID(),
            occupant: fixture.original
        )
        var currentRouting = fixture.snapshot(occupant: fixture.original)

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            until: .idle,
            timeoutMilliseconds: 0,
            prepare: {
                let preparation = AgentWaitCoordinator.Preparation(
                    afterSequence: fixture.bus.latestSequence,
                    surface: currentRouting
                )
                fixture.bus.publish(
                    name: "surface.closed",
                    category: "surface",
                    source: "workspace.lifecycle",
                    workspaceId: fixture.workspaceID.uuidString,
                    surfaceId: fixture.surfaceID.uuidString,
                    paneId: fixture.paneID.uuidString,
                    payload: ["origin": "detach"]
                )
                currentRouting = destination
                return preparation
            },
            routingSnapshot: { _ in currentRouting }
        )

        let value = try result.get()
        #expect(value.status == .timedOut)
        #expect(value.workspaceID == destination.workspaceID)
        #expect(value.surfaceID == destination.surfaceID)
        #expect(value.paneID == destination.paneID)
    }

    @Test
    func transferIntoDockTerminatesInsteadOfWaitingOnFrozenLifecycle() {
        let fixture = Fixture(state: .running)
        var currentRouting = fixture.snapshot(occupant: fixture.original)
        let dockRouting = AgentWaitSurfaceSnapshot(
            workspaceID: UUID(),
            surfaceID: fixture.surfaceID,
            paneID: UUID(),
            occupant: fixture.original,
            hasAuthoritativeLiveLifecycle: false
        )

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            until: .idle,
            timeoutMilliseconds: nil,
            prepare: {
                let preparation = AgentWaitCoordinator.Preparation(
                    afterSequence: fixture.bus.latestSequence,
                    surface: currentRouting
                )
                fixture.bus.publish(
                    name: "surface.closed",
                    category: "surface",
                    source: "workspace.lifecycle",
                    workspaceId: fixture.workspaceID.uuidString,
                    surfaceId: fixture.surfaceID.uuidString,
                    paneId: fixture.paneID.uuidString,
                    payload: ["origin": "detach"]
                )
                currentRouting = dockRouting
                return preparation
            },
            routingSnapshot: { _ in currentRouting }
        )

        #expect(result == .failure(.liveLifecycleUnavailable))
    }

    @Test
    func destinationClosureRefreshesRoutingWithoutLifecycleTransition() throws {
        let fixture = Fixture(state: .running)
        let destinationWorkspaceID = UUID()
        let destinationPaneID = UUID()

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            until: .idle,
            timeoutMilliseconds: 1_000,
            prepare: {
                fixture.preparation(occupant: fixture.original) {
                    fixture.bus.publish(
                        name: "surface.closed",
                        category: "surface",
                        source: "workspace.lifecycle",
                        workspaceId: fixture.workspaceID.uuidString,
                        surfaceId: fixture.surfaceID.uuidString,
                        paneId: fixture.paneID.uuidString,
                        payload: ["origin": "detach"]
                    )
                    fixture.bus.publish(
                        name: "surface.closed",
                        category: "surface",
                        source: "workspace.lifecycle",
                        workspaceId: destinationWorkspaceID.uuidString,
                        surfaceId: fixture.surfaceID.uuidString,
                        paneId: destinationPaneID.uuidString,
                        payload: ["origin": "tab_close"]
                    )
                }
            }
        )

        let value = try result.get()
        #expect(value.status == .surfaceClosed)
        #expect(value.workspaceID == destinationWorkspaceID)
        #expect(value.surfaceID == fixture.surfaceID)
        #expect(value.paneID == destinationPaneID)
    }

    @Test
    func subscriptionAdmissionBoundsConcurrentWaitsAndRecoversAfterRelease() throws {
        let fixture = Fixture(state: .running)
        var reservations = (0..<32).map { _ in
            fixture.bus.subscribe(
                afterSequence: nil,
                names: ["agent.state.changed"],
                categories: [],
                surfaceIDs: [fixture.surfaceID.uuidString]
            )
        }
        defer {
            for reservation in reservations {
                fixture.bus.unsubscribe(reservation.subscription)
            }
        }

        let blocked = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            until: .idle,
            timeoutMilliseconds: 0,
            prepare: { fixture.preparation(occupant: fixture.original) }
        )
        #expect(blocked == .failure(.subscriptionClosed))

        fixture.bus.unsubscribe(reservations.removeLast().subscription)
        let admitted = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            until: .idle,
            timeoutMilliseconds: 1_000,
            prepare: {
                fixture.preparation(occupant: fixture.original) {
                    fixture.publish(
                        record: fixture.original,
                        state: .idle,
                        previous: .running
                    )
                }
            }
        )

        let value = try admitted.get()
        #expect(value.status == .satisfied)
        #expect(value.state == .idle)
    }

    private struct Fixture {
        let bus: CmuxEventBus
        let workspaceID = UUID()
        let surfaceID = UUID()
        let paneID = UUID()
        let original: AgentLifecycleRecord

        init(
            state: AgentHibernationLifecycleState,
            maxPendingEvents: Int = CmuxEventBus.defaultMaxPendingEventsPerSubscription
        ) {
            bus = CmuxEventBus(
                retainedEventLimit: 16,
                maxPendingEventsPerSubscription: maxPendingEvents
            )
            original = AgentLifecycleRecord(
                agent: "codex",
                state: state,
                sessionID: "session-old",
                revision: 41
            )
        }

        func snapshot(occupant: AgentLifecycleRecord?) -> AgentWaitSurfaceSnapshot {
            AgentWaitSurfaceSnapshot(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                paneID: paneID,
                occupant: occupant
            )
        }

        func preparation(
            occupant: AgentLifecycleRecord?,
            action: () -> Void = {}
        ) -> AgentWaitCoordinator.Preparation {
            let afterSequence = bus.latestSequence
            action()
            return AgentWaitCoordinator.Preparation(
                afterSequence: afterSequence,
                surface: snapshot(occupant: occupant)
            )
        }

        func publish(
            record: AgentLifecycleRecord,
            state: AgentLifecyclePublicState,
            previous: AgentLifecyclePublicState?
        ) {
            bus.publishAgentStateChanged(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                paneID: paneID,
                record: record,
                state: state,
                previousState: previous
            )
        }
    }
}
