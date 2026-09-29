import CmuxIrxTransport
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A legacy-dialect (`cmux/mobile/1`) phone admitted while allowed must lose
/// access as soon as the directory revokes it, like an irx phone does.
struct MobileHostIrxLegacyDialectAuthorizationTests {
    private static let endpoint = "abcd1234"

    private static func list(
        entry: IrxDeviceListEntry?,
        ttlSeconds: Int = 600,
        receivedAt: ContinuousClock.Instant = .now
    ) -> IrxDeviceListSnapshot {
        IrxDeviceListSnapshot(
            entries: entry.map { [endpoint: $0] } ?? [:],
            rev: 1,
            issuedAt: Date(),
            ttlSeconds: ttlSeconds,
            receivedAtWall: Date(),
            receivedAtMonotonic: receivedAt
        )
    }

    private static func authorized(
        _ list: IrxDeviceListSnapshot?,
        listeningEnabled: Bool = true,
        now: ContinuousClock.Instant = .now
    ) -> Bool {
        MobileHostIrxLegacyDialectServer.isStillAuthorized(
            remoteEndpoint: endpoint,
            list: list,
            listeningEnabled: listeningEnabled,
            now: now
        )
    }

    @Test func listedPeerOnAFreshListStaysAuthorized() {
        #expect(Self.authorized(Self.list(entry: IrxDeviceListEntry(status: "active", revoked: false))))
    }

    @Test func revokedPeerLosesAuthorization() {
        #expect(!Self.authorized(Self.list(entry: IrxDeviceListEntry(status: "active", revoked: true))))
    }

    @Test func peerDroppedFromTheListLosesAuthorization() {
        #expect(!Self.authorized(Self.list(entry: nil)))
        #expect(!Self.authorized(nil))
    }

    @Test func peerUpgradedToV2LosesLegacyAuthorization() {
        let entry = IrxDeviceListEntry(
            status: "active",
            revoked: false,
            capabilities: [LegacyCompatibilityService.v2Capability]
        )
        #expect(!Self.authorized(Self.list(entry: entry)))
    }

    @Test func staleListLosesAuthorization() {
        let receivedAt = ContinuousClock.Instant.now
        let list = Self.list(
            entry: IrxDeviceListEntry(status: "active", revoked: false),
            ttlSeconds: 60,
            receivedAt: receivedAt
        )
        #expect(Self.authorized(list, now: receivedAt.advanced(by: .seconds(59))))
        #expect(!Self.authorized(list, now: receivedAt.advanced(by: .seconds(61))))
    }

    @Test func disablingListeningRemovesAuthorization() {
        let list = Self.list(entry: IrxDeviceListEntry(status: "active", revoked: false))
        #expect(!Self.authorized(list, listeningEnabled: false))
    }

    @Test func enforcementClosesOnlySessionsThatLostAuthorization() async {
        let sessions = MobileHostIrxLegacyDialectSessions()
        let revokedFlag = LockedFlag(true)
        let revokedClosed = LockedFlag(false)
        let keptClosed = LockedFlag(false)

        let revokedRegistered = await sessions.register(
            id: UUID(),
            stillAuthorized: { revokedFlag.value },
            close: { revokedClosed.set(true) }
        )
        let keptRegistered = await sessions.register(
            id: UUID(),
            stillAuthorized: { true },
            close: { keptClosed.set(true) }
        )
        #expect(revokedRegistered)
        #expect(keptRegistered)

        await sessions.closeUnauthorized()
        #expect(!revokedClosed.value)
        #expect(await sessions.activeSessionCount == 2)

        revokedFlag.set(false)
        await sessions.closeUnauthorized()
        #expect(revokedClosed.value)
        #expect(!keptClosed.value)
        #expect(await sessions.activeSessionCount == 1)
    }

    @Test func alreadyRevokedSessionIsNotRegistered() async {
        let sessions = MobileHostIrxLegacyDialectSessions()
        let registered = await sessions.register(
            id: UUID(),
            stillAuthorized: { false },
            close: {}
        )
        #expect(!registered)
        #expect(await sessions.activeSessionCount == 0)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) {
        stored = value
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Bool) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
