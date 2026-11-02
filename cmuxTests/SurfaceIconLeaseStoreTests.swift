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
        let store = SurfaceIconLeaseStore { _, image in if image == nil { clears += 1 } }
        let panel = UUID()
        let first = try store.set(panelID: panel, ownerID: "session-a", animation: animation)
        // Reads and rejected requests cannot invalidate a retained icon. There is no deadline to drive.
        for _ in 0..<100 {
            #expect(store.entry(for: panel)?.animation == animation)
            #expect(throws: SurfaceIconLeaseStore.LeaseError.staleToken) {
                try store.set(panelID: panel, ownerID: "session-a", token: UUID(), expectedRevision: 1)
            }
        }
        #expect(store.entry(for: panel)?.token == first.token)
        #expect(clears == 0)
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
