import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Retained surface icons")
struct SurfaceIconLeaseStoreTests {
    private var animation: TabIconAnimation {
        TabIconAnimation(id: "test", frames: [Data([1])], durations: [0.1], loops: true)
    }

    @Test func lastIconSurvivesWithoutUpdatesBeyondFormerDeadline() throws {
        var clears = 0
        let clock = CloudReadManualClock()
        let store = SurfaceIconLeaseStore(clock: clock) { _, image in if image == nil { clears += 1 } }
        let panel = UUID()
        let first = try store.set(panelID: panel, ownerID: "session-a", animation: animation)
        clock.advance(by: .seconds(1_000_000))
        #expect(first.ttlSeconds == nil)
        // Reads and rejected requests cannot invalidate an indefinite icon.
        for _ in 0..<100 {
            #expect(store.entry(for: panel)?.animation == animation)
            #expect(throws: SurfaceIconLeaseStore.LeaseError.staleToken) {
                try store.set(panelID: panel, ownerID: "session-a", token: UUID(), expectedRevision: 1)
            }
        }
        #expect(store.entry(for: panel)?.token == first.token)
        #expect(clears == 0)
    }

    @Test func timedIconExpiresAtExactBoundary() throws {
        let clock = CloudReadManualClock()
        var clears = 0
        let store = SurfaceIconLeaseStore(clock: clock) { _, image in
            if image == nil { clears += 1 }
        }
        let panel = UUID()
        try store.set(panelID: panel, ownerID: "a", animation: animation, ttlSeconds: 600)
        clock.advance(by: .seconds(599), deliverTimers: false)
        #expect(store.entry(for: panel) != nil)
        clock.advance(by: .seconds(1), deliverTimers: false)
        #expect(store.entry(for: panel) == nil)
        #expect(clears == 1)
        #expect(store.entry(for: panel) == nil)
        #expect(clears == 1)
    }

    @Test(.timeLimit(.minutes(1))) func automaticExpiryDoesNotRequireAReadOrTimelyTaskStartup() async throws {
        let clock = CloudReadManualClock()
        let (events, continuation) = AsyncStream<UUID>.makeStream()
        let store = SurfaceIconLeaseStore(clock: clock) { panel, image in
            if image == nil { continuation.yield(panel) }
        }
        let panel = UUID()
        try store.set(panelID: panel, ownerID: "a", animation: animation, ttlSeconds: 600)
        // Advance before the expiration task gets its first actor turn.
        clock.advance(by: .seconds(600))
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == panel)
        #expect(store.entry(for: panel) == nil)
        continuation.finish()
    }

    @Test func heartbeatInheritsIntervalWithoutReplacingAnimation() throws {
        let clock = CloudReadManualClock()
        let store = SurfaceIconLeaseStore(clock: clock) { _, _ in }
        let panel = UUID()
        let first = try store.set(panelID: panel, ownerID: "a", animation: animation, ttlSeconds: 600)
        clock.advance(by: .seconds(500), deliverTimers: false)
        let renewed = try store.set(panelID: panel, ownerID: "a", token: first.token, expectedRevision: 1)
        #expect(renewed.ttlSeconds == 600)
        #expect(renewed.token == first.token)
        #expect(renewed.generation == first.generation)
        #expect(renewed.animation == first.animation)
        #expect(renewed.revision == 2)
        clock.advance(by: .seconds(100))
        #expect(store.entry(for: panel)?.revision == 2)
        clock.advance(by: .seconds(499), deliverTimers: false)
        #expect(store.entry(for: panel) != nil)
        clock.advance(by: .seconds(1), deliverTimers: false)
        #expect(store.entry(for: panel) == nil)
    }

    @Test func explicitHeartbeatChangesIntervalAndFullReplacementRestoresIndefinite() throws {
        let clock = CloudReadManualClock()
        let store = SurfaceIconLeaseStore(clock: clock) { _, _ in }
        let panel = UUID()
        let first = try store.set(panelID: panel, ownerID: "a", animation: animation, ttlSeconds: 600)
        clock.advance(by: .seconds(100), deliverTimers: false)
        let renewed = try store.set(panelID: panel, ownerID: "a", token: first.token,
                                    expectedRevision: 1, ttlSeconds: 1)
        #expect(renewed.ttlSeconds == 1)
        let replacement = try store.set(panelID: panel, ownerID: "a", animation: animation)
        #expect(replacement.ttlSeconds == nil)
        clock.advance(by: .seconds(10_000))
        #expect(store.entry(for: panel)?.token == replacement.token)
        let heartbeat = try store.set(panelID: panel, ownerID: "a", token: replacement.token, expectedRevision: 1)
        #expect(heartbeat.ttlSeconds == nil)
    }

    @Test func failedRequestsDoNotExtendDeadline() throws {
        let clock = CloudReadManualClock()
        let store = SurfaceIconLeaseStore(clock: clock) { _, _ in }
        let panel = UUID()
        let first = try store.set(panelID: panel, ownerID: "a", animation: animation, ttlSeconds: 600)
        clock.advance(by: .seconds(599), deliverTimers: false)
        #expect(throws: SurfaceIconLeaseStore.LeaseError.ownershipConflict) {
            try store.set(panelID: panel, ownerID: "b", token: first.token, expectedRevision: 1, ttlSeconds: 900)
        }
        #expect(throws: SurfaceIconLeaseStore.LeaseError.staleToken) {
            try store.set(panelID: panel, ownerID: "a", token: UUID(), expectedRevision: 1)
        }
        #expect(throws: SurfaceIconLeaseStore.LeaseError.revisionConflict) {
            try store.set(panelID: panel, ownerID: "a", token: first.token, expectedRevision: 2)
        }
        #expect(store.entry(for: panel)?.revision == 1)
        clock.advance(by: .seconds(1), deliverTimers: false)
        #expect(store.entry(for: panel) == nil)
    }

    @Test func expiredCredentialsCannotRenewOrClearEvenWithDelayedTimer() throws {
        let clock = CloudReadManualClock()
        let store = SurfaceIconLeaseStore(clock: clock) { _, _ in }
        let panel = UUID()
        let first = try store.set(panelID: panel, ownerID: "a", animation: animation, ttlSeconds: 600)
        clock.advance(by: .seconds(600), deliverTimers: false)
        #expect(throws: SurfaceIconLeaseStore.LeaseError.staleToken) {
            try store.set(panelID: panel, ownerID: "a", token: first.token, expectedRevision: 1, ttlSeconds: 600)
        }
        #expect(throws: SurfaceIconLeaseStore.LeaseError.staleToken) {
            try store.clear(panelID: panel, ownerID: "a", token: first.token, expectedRevision: 1)
        }
        #expect(store.entry(for: panel) == nil)
    }

    @Test func replacementAndResetArePanelScoped() throws {
        let clock = CloudReadManualClock()
        let store = SurfaceIconLeaseStore(clock: clock) { _, _ in }
        let a = UUID(), b = UUID()
        try store.set(panelID: a, ownerID: "a", animation: animation, ttlSeconds: 1)
        try store.set(panelID: b, ownerID: "b", animation: animation, ttlSeconds: 600)
        let replacement = try store.set(panelID: a, ownerID: "a", animation: animation, ttlSeconds: 900)
        clock.advance(by: .seconds(1))
        #expect(store.entry(for: a)?.token == replacement.token)
        store.reset(panelID: a)
        #expect(store.entry(for: a) == nil)
        #expect(store.entry(for: b) != nil)
        store.resetAll()
        #expect(store.entry(for: b) == nil)
    }

    @Test func hugeTTLIsRepresentableAndInvalidTTLDoesNotChangeState() throws {
        let clock = CloudReadManualClock()
        let store = SurfaceIconLeaseStore(clock: clock) { _, _ in }
        let panel = UUID()
        let first = try store.set(panelID: panel, ownerID: "a", animation: animation, ttlSeconds: Int.max)
        clock.advance(by: .seconds(31_536_000))
        #expect(store.entry(for: panel)?.ttlSeconds == Int.max)
        for invalid in [0, -1] {
            #expect(throws: SurfaceIconLeaseStore.LeaseError.invalidTTL) {
                try store.set(panelID: panel, ownerID: "a", token: first.token, expectedRevision: 1,
                              ttlSeconds: invalid)
            }
        }
        #expect(store.entry(for: panel)?.revision == 1)
        let renewed = try store.set(panelID: panel, ownerID: "a", token: first.token, expectedRevision: 1)
        #expect(renewed.ttlSeconds == Int.max)
    }

    @Test(.timeLimit(.minutes(1))) func queuedExpiredTaskCannotClearAReplacement() async throws {
        let clock = CloudReadManualClock()
        let (events, continuation) = AsyncStream<UUID>.makeStream()
        var clears: [UUID] = []
        let store = SurfaceIconLeaseStore(clock: clock) { panel, image in
            if image == nil {
                clears.append(panel)
                continuation.yield(panel)
            }
        }
        let replaced = UUID(), barrier = UUID()
        try store.set(panelID: replaced, ownerID: "a", animation: animation, ttlSeconds: 1)
        clock.advance(by: .seconds(1))
        // Old task is ready, but has not resumed on the main actor.
        let replacement = try store.set(panelID: replaced, ownerID: "b", animation: animation)
        // A second automatic expiration provides an observable async barrier, without sleeps/polling.
        try store.set(panelID: barrier, ownerID: "c", animation: animation, ttlSeconds: 1)
        clock.advance(by: .seconds(1))
        var iterator = events.makeAsyncIterator()
        // The replacement reconciles the original expired entry synchronously.
        #expect(await iterator.next() == replaced)
        #expect(await iterator.next() == barrier)
        #expect(store.entry(for: replaced)?.token == replacement.token)
        #expect(clears.filter { $0 == replaced }.count == 1)
        continuation.finish()
    }

    @Test(.timeLimit(.minutes(1))) func resetAndDeallocationCancelPendingTasks() async throws {
        let clock = CloudReadManualClock()
        var store: SurfaceIconLeaseStore? = SurfaceIconLeaseStore(clock: clock) { _, _ in }
        weak var releasedStore = store
        try #require(store).set(panelID: UUID(), ownerID: "a", animation: animation, ttlSeconds: Int.max)
        store?.resetAll()
        #expect(clock.pendingSleeperCount == 0)
        try #require(store).set(panelID: UUID(), ownerID: "b", animation: animation, ttlSeconds: Int.max)
        store = nil
        #expect(releasedStore == nil)
        releasedStore = nil
        // Let canceled tasks drain using a real expiry callback as an observable barrier.
        let (events, continuation) = AsyncStream<UUID>.makeStream()
        let other = SurfaceIconLeaseStore(clock: clock) { panel, image in
            if image == nil { continuation.yield(panel) }
        }
        let panel = UUID()
        try other.set(panelID: panel, ownerID: "c", animation: animation, ttlSeconds: 1)
        clock.advance(by: .seconds(1))
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == panel)
        #expect(clock.pendingSleeperCount == 0)
        continuation.finish()
    }

    @Test func conditionalUpdatesAndClear() throws {
        var changes: [TabIconAnimation?] = []
        let store = SurfaceIconLeaseStore { _, image in changes.append(image) }
        let panel = UUID(), owner = "session-a"
        let first = try store.set(panelID: panel, ownerID: owner, animation: animation)
        #expect(first.revision == 1)
        let unchanged = try store.set(panelID: panel, ownerID: owner, token: first.token, expectedRevision: 1)
        #expect(unchanged.token == first.token)
        #expect(unchanged.generation == first.generation)
        #expect(unchanged.revision == 2)
        #expect(unchanged.animation == animation)
        let next = TabIconAnimation(id: "done", frames: [Data([2])], durations: [0.1], loops: false)
        let updated = try store.set(panelID: panel, ownerID: owner, token: first.token,
                                    expectedRevision: 2, animation: next)
        #expect(updated.animation == next)
        #expect(throws: SurfaceIconLeaseStore.LeaseError.revisionConflict) {
            try store.clear(panelID: panel, ownerID: owner, token: first.token, expectedRevision: 2)
        }
        #expect(store.entry(for: panel)?.animation == next)
        try store.clear(panelID: panel, ownerID: owner, token: updated.token, expectedRevision: 3)
        #expect(store.entry(for: panel) == nil)
        #expect(changes.count == 4)
        #expect(changes.last! == nil)
    }

    @Test func ownershipAndTokenConflictsNeverChangeIcon() throws {
        let store = SurfaceIconLeaseStore { _, _ in }
        let panel = UUID(), owner = "session-a"
        let first = try store.set(panelID: panel, ownerID: owner, animation: animation)
        #expect(throws: SurfaceIconLeaseStore.LeaseError.ownershipConflict) {
            try store.set(panelID: panel, ownerID: "session-b", token: first.token, expectedRevision: 1, animation: animation)
        }
        #expect(throws: SurfaceIconLeaseStore.LeaseError.staleToken) {
            try store.set(panelID: panel, ownerID: owner, token: UUID(), expectedRevision: 1, animation: animation)
        }
        #expect(throws: SurfaceIconLeaseStore.LeaseError.revisionConflict) {
            try store.set(panelID: panel, ownerID: owner, token: first.token, animation: animation)
        }
        #expect(throws: SurfaceIconLeaseStore.LeaseError.ownershipConflict) {
            try store.clear(panelID: panel, ownerID: "session-b", token: first.token, expectedRevision: 1)
        }
        #expect(throws: SurfaceIconLeaseStore.LeaseError.revisionConflict) {
            try store.clear(panelID: panel, ownerID: owner, token: first.token)
        }
        #expect(store.entry(for: panel)?.token == first.token)
    }

    @Test func fullReplacementReacquiresAfterProducerRestartAndRejectsOldCredentials() throws {
        let store = SurfaceIconLeaseStore { _, _ in }
        let panel = UUID()
        let first = try store.set(panelID: panel, ownerID: "boot-a", animation: animation)
        let second = try store.set(panelID: panel, ownerID: "boot-b", animation: animation)
        #expect(second.token != first.token)
        #expect(second.generation != first.generation)
        #expect(second.revision == 1)
        #expect(throws: SurfaceIconLeaseStore.LeaseError.ownershipConflict) {
            try store.clear(panelID: panel, ownerID: "boot-a", token: first.token, expectedRevision: 1)
        }
        #expect(throws: SurfaceIconLeaseStore.LeaseError.ownershipConflict) {
            try store.set(panelID: panel, ownerID: "boot-a", token: first.token, expectedRevision: 1, animation: animation)
        }
        let third = try store.set(panelID: panel, ownerID: "boot-b", animation: animation)
        #expect(third.token != second.token)
        #expect(throws: SurfaceIconLeaseStore.LeaseError.staleToken) {
            try store.clear(panelID: panel, ownerID: "boot-b", token: second.token, expectedRevision: 1)
        }
        #expect(store.entry(for: panel)?.token == third.token)
    }

    @Test func resetInvalidatesTokensAndIsPanelScoped() throws {
        var cleared: Set<UUID> = []
        let store = SurfaceIconLeaseStore { panel, image in if image == nil { cleared.insert(panel) } }
        let a = UUID(), b = UUID(), owner = "session-a"
        #expect(throws: SurfaceIconLeaseStore.LeaseError.missingAnimation) {
            try store.set(panelID: a, ownerID: owner)
        }
        #expect(throws: SurfaceIconLeaseStore.LeaseError.revisionConflict) {
            try store.set(panelID: a, ownerID: owner, expectedRevision: 1, animation: animation)
        }
        let first = try store.set(panelID: a, ownerID: owner, animation: animation)
        try store.set(panelID: b, ownerID: owner, animation: animation)
        store.reset(panelID: a)
        #expect(throws: SurfaceIconLeaseStore.LeaseError.staleToken) {
            try store.set(panelID: a, ownerID: owner, token: first.token, expectedRevision: 1, animation: animation)
        }
        #expect(store.entry(for: b) != nil)
        store.resetAll()
        store.resetAll()
        #expect(store.entry(for: b) == nil)
        #expect(cleared == [a, b])
    }
}
