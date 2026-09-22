import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Control handle ordinal persistence")
struct ControlHandleOrdinalPersistenceTests {
    @Test func firstUpgradedLaunchLeavesLegacyLowRefsUnknown() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: try! #require(defaults.volatileDomainNames.first)) }

        let store = ControlHandleOrdinalDefaultsStore(defaults: defaults)
        var registry = store.makeRegistry()
        let id = UUID()

        #expect(
            registry.ensureRef(kind: .surface, uuid: id)
                == "surface:\(ControlHandleOrdinalDefaultsStore.defaultMigrationFloor)"
        )
        #expect(registry.uuid(forRef: "surface:1") == nil)
    }

    @Test func aLaterLaunchStartsOutsideThePriorReservation() throws {
        let suite = "cmux-control-handle-ordinals-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let firstStore = ControlHandleOrdinalDefaultsStore(
            defaults: defaults,
            migrationFloor: 100,
            reservationSize: 3
        )
        var firstRegistry = firstStore.makeRegistry()
        let firstID = UUID()
        let firstRef = firstRegistry.ensureRef(kind: .surface, uuid: firstID)
        #expect(firstRef == "surface:100")

        let secondStore = ControlHandleOrdinalDefaultsStore(
            defaults: defaults,
            migrationFloor: 100,
            reservationSize: 3
        )
        var secondRegistry = secondStore.makeRegistry()
        let secondID = UUID()
        let secondRef = secondRegistry.ensureRef(kind: .surface, uuid: secondID)

        #expect(secondRef == "surface:103")
        #expect(secondRegistry.uuid(forRef: firstRef) == nil)
        #expect(secondRegistry.uuid(forRef: secondRef) == secondID)
    }

    @Test func exhaustingAReservationAdvancesTheNextLaunch() throws {
        let suite = "cmux-control-handle-ordinal-extension-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let firstStore = ControlHandleOrdinalDefaultsStore(
            defaults: defaults,
            migrationFloor: 200,
            reservationSize: 2
        )
        var firstRegistry = firstStore.makeRegistry()
        #expect(firstRegistry.ensureRef(kind: .surface, uuid: UUID()) == "surface:200")
        #expect(firstRegistry.ensureRef(kind: .surface, uuid: UUID()) == "surface:201")

        let secondStore = ControlHandleOrdinalDefaultsStore(
            defaults: defaults,
            migrationFloor: 200,
            reservationSize: 2
        )
        var secondRegistry = secondStore.makeRegistry()
        #expect(secondRegistry.ensureRef(kind: .surface, uuid: UUID()) == "surface:204")
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "cmux-control-handle-legacy-floor-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suite))
    }
}
