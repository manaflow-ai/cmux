import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Surface icon conditional leases")
struct SurfaceIconLeaseStoreTests {
    private let instant = Date(timeIntervalSince1970: 1000)

    private var animation: TabIconAnimation {
        TabIconAnimation(id: "test", frames: [Data([1])], durations: [0.1], loops: true)
    }

    private func store(onChange: @escaping (UUID, TabIconAnimation?) -> Void = { _, _ in }) -> SurfaceIconLeaseStore {
        SurfaceIconLeaseStore(now: { instant }, sleep: { _ in
            // No wall-clock timer is needed: tests deliver expiration explicitly.
            try await Task.sleep(for: .seconds(3600))
        }, onChange: onChange)
    }

    @Test func acquisitionRenewalAndConditionalClear() throws {
        var changes: [TabIconAnimation?] = []
        let store = store { _, animation in changes.append(animation) }
        let panel = UUID(), owner = "session-a"
        let first = try store.set(panelID: panel, ownerID: owner, animation: animation, ttl: 10)
        #expect(first.revision == 1)
        #expect(first.expiresAt == instant.addingTimeInterval(10))
        let renewed = try store.set(panelID: panel, ownerID: owner, token: first.token,
                                    expectedRevision: 1, ttl: 20)
        #expect(renewed.token == first.token)
        #expect(renewed.generation == first.generation)
        #expect(renewed.revision == 2)
        #expect(renewed.animation == animation)
        #expect(renewed.expiresAt == instant.addingTimeInterval(20))
        #expect(throws: SurfaceIconLeaseStore.LeaseError.revisionConflict) {
            try store.clear(panelID: panel, ownerID: owner, token: first.token, expectedRevision: 1)
        }
        #expect(store.entry(for: panel)?.revision == 2)
        try store.clear(panelID: panel, ownerID: owner, token: renewed.token, expectedRevision: 2)
        #expect(store.entry(for: panel) == nil)
        #expect(changes.count == 3)
        #expect(changes.last! == nil)
    }

    @Test func ownershipAndTokenConflictsNeverChangeLease() throws {
        let store = store()
        let panel = UUID(), owner = "session-a"
        let first = try store.set(panelID: panel, ownerID: owner, animation: animation, ttl: 10)
        #expect(throws: SurfaceIconLeaseStore.LeaseError.ownershipConflict) {
            try store.set(panelID: panel, ownerID: "session-b", token: first.token, animation: animation, ttl: 10)
        }
        #expect(throws: SurfaceIconLeaseStore.LeaseError.staleToken) {
            try store.set(panelID: panel, ownerID: owner, animation: animation, ttl: 10)
        }
        #expect(throws: SurfaceIconLeaseStore.LeaseError.staleToken) {
            try store.set(panelID: panel, ownerID: owner, token: UUID(), animation: animation, ttl: 10)
        }
        #expect(throws: SurfaceIconLeaseStore.LeaseError.ownershipConflict) {
            try store.clear(panelID: panel, ownerID: "session-b", token: first.token)
        }
        #expect(throws: SurfaceIconLeaseStore.LeaseError.staleToken) {
            try store.clear(panelID: panel, ownerID: owner, token: UUID())
        }
        #expect(store.entry(for: panel)?.revision == 1)
    }

    @Test func expiredAndResetTokensCannotReacquireVacantPanel() throws {
        let store = store()
        let panel = UUID(), owner = "session-a"
        let first = try store.set(panelID: panel, ownerID: owner, animation: animation, ttl: 10)
        #expect(!store.expire(panelID: panel, token: first.token, revision: first.revision,
                              at: instant.addingTimeInterval(9)))
        #expect(store.expire(panelID: panel, token: first.token, revision: first.revision,
                             at: instant.addingTimeInterval(10)))
        #expect(throws: SurfaceIconLeaseStore.LeaseError.staleToken) {
            try store.set(panelID: panel, ownerID: owner, token: first.token, animation: animation, ttl: 10)
        }
        #expect(throws: SurfaceIconLeaseStore.LeaseError.staleToken) {
            try store.clear(panelID: panel, ownerID: owner, token: first.token)
        }
        let second = try store.set(panelID: panel, ownerID: owner, animation: animation, ttl: 10)
        #expect(second.generation != first.generation)
        #expect(second.token != first.token)
        #expect(!store.expire(panelID: panel, token: first.token, revision: first.revision,
                              at: instant.addingTimeInterval(100)))
        store.reset(panelID: panel)
        #expect(throws: SurfaceIconLeaseStore.LeaseError.staleToken) {
            try store.set(panelID: panel, ownerID: owner, token: second.token, animation: animation, ttl: 10)
        }
    }

    @Test func staleExpirationCannotClearRenewal() throws {
        var cleared = 0
        let store = store { _, animation in if animation == nil { cleared += 1 } }
        let panel = UUID(), owner = "session-a"
        let first = try store.set(panelID: panel, ownerID: owner, animation: animation, ttl: 10)
        let second = try store.set(panelID: panel, ownerID: owner, token: first.token, ttl: 20)
        #expect(!store.expire(panelID: panel, token: first.token, revision: first.revision,
                              at: instant.addingTimeInterval(100)))
        #expect(cleared == 0)
        #expect(store.expire(panelID: panel, token: second.token, revision: second.revision,
                             at: instant.addingTimeInterval(20)))
        #expect(cleared == 1)
    }

    @Test func validationAndResetAllArePanelScoped() throws {
        var cleared: Set<UUID> = []
        let store = store { panel, animation in if animation == nil { cleared.insert(panel) } }
        let a = UUID(), b = UUID(), owner = "session-a"
        for ttl in [0, -1, 4.999, 120.001, .infinity, .nan] {
            #expect(throws: SurfaceIconLeaseStore.LeaseError.invalidTTL) {
                try store.set(panelID: a, ownerID: owner, animation: animation, ttl: ttl)
            }
        }
        #expect(throws: SurfaceIconLeaseStore.LeaseError.missingAnimation) {
            try store.set(panelID: a, ownerID: owner, ttl: 10)
        }
        #expect(throws: SurfaceIconLeaseStore.LeaseError.revisionConflict) {
            try store.set(panelID: a, ownerID: owner, expectedRevision: 1, animation: animation, ttl: 10)
        }
        try store.set(panelID: a, ownerID: owner, animation: animation, ttl: 10)
        try store.set(panelID: b, ownerID: owner, animation: animation, ttl: 10)
        store.reset(panelID: a)
        #expect(store.entry(for: b) != nil)
        store.resetAll()
        store.resetAll()
        #expect(store.entry(for: b) == nil)
        #expect(cleared == [a, b])
    }

    @Test(arguments: [5.0, 120.0])
    func acceptsTTLBoundary(_ ttl: TimeInterval) throws {
        let store = store()
        let panel = UUID()
        let lease = try store.set(panelID: panel, ownerID: "session-a", animation: animation, ttl: ttl)
        #expect(lease.ownerID == "session-a")
        #expect(lease.expiresAt == instant.addingTimeInterval(ttl))
    }

    @Test func scheduledExpirationDeliversClearWithoutPolling() async throws {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let cleared = AsyncStream<UUID>.makeStream()
        var time = instant
        let store = SurfaceIconLeaseStore(now: { time }, sleep: { _ in
            started.continuation.yield(())
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
        }, onChange: { panel, animation in
            if animation == nil { cleared.continuation.yield(panel) }
        })
        let panel = UUID()
        try store.set(panelID: panel, ownerID: "session-b", animation: animation, ttl: 10)
        var starts = started.stream.makeAsyncIterator()
        _ = await starts.next()
        time = time.addingTimeInterval(10)
        release.continuation.yield(())
        var changes = cleared.stream.makeAsyncIterator()
        let expiredPanel = await changes.next()
        #expect(expiredPanel == panel)
        #expect(store.entry(for: panel) == nil)
        started.continuation.finish()
        release.continuation.finish()
        cleared.continuation.finish()
    }

    @Test func getterExpiresLazilyAtInjectedDeadline() throws {
        var time = instant
        var clears = 0
        let store = SurfaceIconLeaseStore(now: { time }, sleep: { _ in
            try await Task.sleep(for: .seconds(3600))
        }, onChange: { _, animation in if animation == nil { clears += 1 } })
        let panel = UUID()
        try store.set(panelID: panel, ownerID: "session-b", animation: animation, ttl: 10)
        time = time.addingTimeInterval(10)
        #expect(store.entry(for: panel) == nil)
        #expect(clears == 1)
    }
}
