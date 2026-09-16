import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxIrxTransport
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct MobileHostIrxSignOutTests {
    @Test("Sign-out immediately blocks networking and drains persisted authorization")
    func clearsRetiredLease() async {
        let runtime = MobileHostIrxRuntime(
            managedDevicePolicy: ManagedDevicePolicy(releaseDomainDefaults: nil, forcedObject: { _, _ in nil }),
            pairingEnabled: { true }
        )
        let now = Date(timeIntervalSince1970: 1_000)
        let store = IrxDeviceListStore(
            secureStore: MobileHostSignOutCredentialStore(), accountID: "retired", backendHost: "test.invalid",
            journal: IrxJournal(subsystem: "cmux.tests", category: "sign-out"), wallNow: { now }
        )
        #expect(await store.persist(IrxDeviceListSnapshot(
            entries: [:], rev: 1, issuedAt: now, ttlSeconds: 60,
            receivedAtWall: now, receivedAtMonotonic: .now
        )))
        #expect(await store.loadPersisted() != nil)
        runtime.deviceListStore = store
        #expect(runtime.canStartNetworking)
        runtime.beginSignOutPreparation()
        #expect(!runtime.canStartNetworking)
        // Reconciliation queues behind sign-out, so completion proves the
        // retired lease was removed without timers or a real endpoint.
        await runtime.applyManagedNetworkingPolicy()
        #expect(await store.loadPersisted() == nil)
        #expect(runtime.endpointSupervisor == nil)
        #expect(runtime.settingsPhase == .idle)
    }

    @Test("An old session stays fenced while a fresh sign-in can activate")
    func freshSessionCanRearm() {
        let transition = MobileHostAuthTransition.signingOut(generation: 10)
        #expect(!transition.permits(nil))
        #expect(!transition.permits(AuthenticatedSessionIdentity(generation: 10, accountID: "account")))
        #expect(transition.permits(AuthenticatedSessionIdentity(generation: 11, accountID: "account")))
        #expect(transition.permits(AuthenticatedSessionIdentity(generation: 12, accountID: "another-account")))
    }
}
