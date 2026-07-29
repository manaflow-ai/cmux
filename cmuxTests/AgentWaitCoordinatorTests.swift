import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct AgentWaitCoordinatorTests {
    @Test
    func stateReachedBeforeWaitStartsReturnsImmediately() throws {
        let fixture = Fixture(state: .idle)

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            surfaceID: fixture.surfaceID,
            until: .idle,
            timeoutMilliseconds: 0,
            snapshot: { fixture.snapshot(occupant: fixture.original) }
        )

        let value = try result.get()
        #expect(value.status == .satisfied)
        #expect(value.state == .idle)
        #expect(value.sessionID == fixture.original.sessionID)
    }

    @Test
    func stateReachedDuringSnapshotSetupSatisfiesWait() throws {
        let fixture = Fixture(state: .running)

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            surfaceID: fixture.surfaceID,
            until: .idle,
            timeoutMilliseconds: 0,
            snapshot: {
                fixture.publish(record: fixture.original, state: .idle, previous: .running)
                return fixture.snapshot(occupant: fixture.original)
            }
        )

        let value = try result.get()
        #expect(value.status == .satisfied)
        #expect(value.state == .idle)
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
            surfaceID: fixture.surfaceID,
            until: .idle,
            timeoutMilliseconds: 1_000,
            snapshot: { fixture.snapshot(occupant: fixture.original) }
        )

        let value = try result.get()
        #expect(value.status == .satisfied)
        #expect(value.state == .idle)
    }

    @Test
    func replacementOccupantCannotSatisfyPinnedWait() throws {
        let fixture = Fixture(state: .running)
        let replacement = AgentLifecycleRecord(
            agent: "codex",
            state: .idle,
            sessionID: "session-new",
            revision: fixture.original.revision + 1
        )

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            surfaceID: fixture.surfaceID,
            until: .idle,
            timeoutMilliseconds: 0,
            snapshot: {
                fixture.publish(record: fixture.original, state: .exit, previous: .running)
                fixture.publish(record: replacement, state: .idle, previous: nil)
                return fixture.snapshot(occupant: fixture.original)
            }
        )

        let value = try result.get()
        #expect(value.status == .timedOut)
        #expect(value.state == .exit)
        #expect(value.sessionID == fixture.original.sessionID)
    }

    @Test
    func zeroTimeoutReturnsTimedOutWithoutPollingState() throws {
        let fixture = Fixture(state: .running)

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            surfaceID: fixture.surfaceID,
            until: .idle,
            timeoutMilliseconds: 0,
            snapshot: { fixture.snapshot(occupant: fixture.original) }
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
            surfaceID: fixture.surfaceID,
            until: .idle,
            timeoutMilliseconds: 250,
            snapshot: { fixture.snapshot(occupant: fixture.original) }
        )

        let value = try result.get()
        #expect(value.status == .timedOut)
        #expect(value.state == .running)
    }

    @Test
    func unrelatedEventsCannotStarveTimeout() throws {
        let fixture = Fixture(state: .running)

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            surfaceID: fixture.surfaceID,
            until: .idle,
            timeoutMilliseconds: 0,
            snapshot: {
                fixture.bus.publish(
                    name: "surface.closed",
                    category: "surface",
                    source: "test",
                    surfaceId: UUID().uuidString
                )
                return fixture.snapshot(occupant: fixture.original)
            }
        )

        let value = try result.get()
        #expect(value.status == .timedOut)
        #expect(value.state == .running)
    }

    @Test
    func unrelatedSurfaceBurstCannotOverflowTargetWait() throws {
        let fixture = Fixture(state: .running, maxPendingEvents: 2)

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            surfaceID: fixture.surfaceID,
            until: .idle,
            timeoutMilliseconds: 0,
            snapshot: {
                for _ in 0..<16 {
                    fixture.bus.publish(
                        name: "agent.state.changed",
                        category: "agent",
                        source: "test",
                        surfaceId: UUID().uuidString
                    )
                }
                fixture.publish(
                    record: fixture.original,
                    state: .idle,
                    previous: .running
                )
                return fixture.snapshot(occupant: fixture.original)
            }
        )

        let value = try result.get()
        #expect(value.status == .satisfied)
        #expect(value.state == .idle)
    }

    @Test
    func needsInputTransitionSatisfiesWait() throws {
        let fixture = Fixture(state: .running)

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            surfaceID: fixture.surfaceID,
            until: .needsInput,
            timeoutMilliseconds: 0,
            snapshot: {
                fixture.publish(
                    record: fixture.original,
                    state: .needsInput,
                    previous: .running
                )
                return fixture.snapshot(occupant: fixture.original)
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
            surfaceID: fixture.surfaceID,
            until: .exit,
            timeoutMilliseconds: 0,
            snapshot: {
                fixture.publish(record: fixture.original, state: .exit, previous: .running)
                return fixture.snapshot(occupant: fixture.original)
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
            surfaceID: fixture.surfaceID,
            until: .idle,
            timeoutMilliseconds: 0,
            snapshot: {
                fixture.publish(record: replacement, state: .idle, previous: nil)
                return fixture.snapshot(occupant: anonymousOccupant)
            }
        )

        let value = try result.get()
        #expect(value.status == .timedOut)
        #expect(value.state == .running)
        #expect(value.sessionID == nil)
    }

    @Test
    func partiallyKnownSessionIdentityDoesNotMatch() {
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

        #expect(!known.identifiesSameOccupant(as: unknown))
        #expect(!unknown.identifiesSameOccupant(as: known))
    }

    @Test
    func subscriptionCloseReasonIsNotPartOfWaitError() {
        let fixture = Fixture(state: .running)
        let coordinator = AgentWaitCoordinator(
            eventBus: fixture.bus,
            onSubscribe: { $0.close(reason: "internal buffer details") }
        )

        let result = coordinator.wait(
            surfaceID: fixture.surfaceID,
            until: .idle,
            timeoutMilliseconds: nil,
            snapshot: { fixture.snapshot(occupant: fixture.original) }
        )

        #expect(result == .failure(.subscriptionClosed))
    }

    @Test
    func surfaceClosureHasDistinctTerminalStatus() throws {
        let fixture = Fixture(state: .running)

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            surfaceID: fixture.surfaceID,
            until: .idle,
            timeoutMilliseconds: 0,
            snapshot: {
                fixture.bus.publish(
                    name: "surface.closed",
                    category: "surface",
                    source: "test",
                    workspaceId: fixture.workspaceID.uuidString,
                    surfaceId: fixture.surfaceID.uuidString,
                    paneId: fixture.paneID.uuidString
                )
                return fixture.snapshot(occupant: fixture.original)
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
            surfaceID: fixture.surfaceID,
            until: .idle,
            timeoutMilliseconds: 1_000,
            snapshot: {
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
                return fixture.snapshot(occupant: fixture.original)
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
            surfaceID: fixture.surfaceID,
            until: .idle,
            timeoutMilliseconds: 0,
            snapshot: {
                let initial = currentRouting
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
                return initial
            },
            routingSnapshot: { currentRouting }
        )

        let value = try result.get()
        #expect(value.status == .timedOut)
        #expect(value.workspaceID == destination.workspaceID)
        #expect(value.surfaceID == destination.surfaceID)
        #expect(value.paneID == destination.paneID)
    }

    @Test
    func destinationClosureRefreshesRoutingWithoutLifecycleTransition() throws {
        let fixture = Fixture(state: .running)
        let destinationWorkspaceID = UUID()
        let destinationPaneID = UUID()

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            surfaceID: fixture.surfaceID,
            until: .idle,
            timeoutMilliseconds: 1_000,
            snapshot: {
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
                return fixture.snapshot(occupant: fixture.original)
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
            surfaceID: fixture.surfaceID,
            until: .idle,
            timeoutMilliseconds: 0,
            snapshot: { fixture.snapshot(occupant: fixture.original) }
        )
        #expect(blocked == .failure(.subscriptionClosed))

        fixture.bus.unsubscribe(reservations.removeLast().subscription)
        let admitted = AgentWaitCoordinator(eventBus: fixture.bus).wait(
            surfaceID: fixture.surfaceID,
            until: .idle,
            timeoutMilliseconds: 1_000,
            snapshot: {
                fixture.publish(
                    record: fixture.original,
                    state: .idle,
                    previous: .running
                )
                return fixture.snapshot(occupant: fixture.original)
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
