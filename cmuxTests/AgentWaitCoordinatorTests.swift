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
    func needsInputTransitionSatisfiesWait() throws {
        let fixture = Fixture(state: .running)

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
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
    func surfaceClosureHasDistinctTerminalStatus() throws {
        let fixture = Fixture(state: .running)

        let result = AgentWaitCoordinator(eventBus: fixture.bus).wait(
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

    private struct Fixture {
        let bus = CmuxEventBus(retainedEventLimit: 16)
        let workspaceID = UUID()
        let surfaceID = UUID()
        let paneID = UUID()
        let original: AgentLifecycleRecord

        init(state: AgentHibernationLifecycleState) {
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
