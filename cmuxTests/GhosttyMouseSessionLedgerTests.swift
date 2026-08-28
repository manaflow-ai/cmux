import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Ghostty mouse session ledger", .serialized)
struct GhosttyMouseSessionLedgerTests {
    @Test("button sessions retain independent generations")
    func buttonSessionsRetainIndependentGenerations() throws {
        let ledger = GhosttyMouseSessionLedger()
        let surface = Self.surfaceIdentity(generation: 4, address: 0x101)
        ledger.transition(to: surface)

        let left = try #require(ledger.begin(.left, on: surface))
        let right = try #require(ledger.begin(.right, on: surface))
        #expect(ledger.activeButtons == [.left, .right])
        #expect(left.generation != right.generation)

        #expect(ledger.finish(left))
        #expect(ledger.hasSession(for: .right, on: surface))
        #expect(!ledger.hasSession(for: .left, on: surface))
    }

    @Test("runtime replacement invalidates old release tokens")
    func runtimeReplacementInvalidatesOldReleaseTokens() throws {
        let ledger = GhosttyMouseSessionLedger()
        let original = Self.surfaceIdentity(generation: 8, address: 0x202)
        let replacement = Self.surfaceIdentity(generation: 9, address: 0x202)
        ledger.transition(to: original)
        let oldSession = try #require(ledger.begin(.left, on: original))

        #expect(ledger.transition(to: replacement))
        #expect(ledger.activeButtons.isEmpty)
        #expect(!ledger.finish(oldSession))

        let newSession = try #require(ledger.begin(.left, on: replacement))
        #expect(newSession.generation != oldSession.generation)
        #expect(!ledger.finish(oldSession))
        #expect(ledger.finish(newSession))
    }

    @Test("physical reconciliation is limited to non-drag repair candidates")
    func physicalReconciliationSelectsOnlyReleasedButtons() throws {
        let ledger = GhosttyMouseSessionLedger()
        let surface = Self.surfaceIdentity(generation: 12, address: 0x303)
        ledger.transition(to: surface)
        _ = try #require(ledger.begin(.left, on: surface))
        _ = try #require(ledger.begin(.right, on: surface))

        let released = ledger.sessionsNeedingRepair(
            on: surface,
            physicalButtons: 1 << 0,
            forcedButtons: []
        )
        #expect(released.map(\.button) == [.right])

        let forced = ledger.sessionsNeedingRepair(
            on: surface,
            physicalButtons: 1 << 0,
            forcedButtons: [.left]
        )
        #expect(Set(forced.map(\.button)) == [.left, .right])
    }

    private static func surfaceIdentity(
        generation: UInt64,
        address: UInt
    ) -> GhosttyMouseSessionLedger.SurfaceIdentity {
        GhosttyMouseSessionLedger.SurfaceIdentity(
            surfaceID: UUID(),
            runtimeGeneration: generation,
            nativeAddress: address
        )
    }
}
