import CMUXMobileCore
import CmuxIrxTransport
import CmuxMobileShellModel
import Foundation
import Testing
@testable import cmuxFeature

@MainActor
@Suite
struct MobileIrxCompatibilityProjectionTests {
    @Test(arguments: [false, true])
    func directoryProjectionKeepsStableAndNightlySeparate(reverseOrder: Bool) throws {
        let records = [
            ("stable-peer", IrxDeviceListEntry(
                deviceID: "physical-mac", status: "active", revoked: false,
                appVersion: "0.64.22", releaseTrack: "stable",
                bindingID: "stable-binding", tag: "default", identityGeneration: 2
            )),
            ("nightly-peer", IrxDeviceListEntry(
                deviceID: "physical-mac", status: "active", revoked: false,
                appVersion: "0.64.22-nightly.3439608067501", releaseTrack: "nightly",
                bindingID: "nightly-binding", tag: "nightly", identityGeneration: 3
            )),
        ]
        let snapshot = snapshot(entries: Dictionary(uniqueKeysWithValues: reverseOrder ? records.reversed() : records))
        let entries = MobileIrxRuntimeComposition.macListAuthEntries(from: snapshot)
        let state = MobileMacListAuthState()
        state.applyPolicyMinimumSupportedMacVersions(stable: "0.64.23", nightly: nil)
        state.replace(entriesByIdentity: entries)

        #expect(entries.count == 2)
        #expect(entries.keys.contains(.init(
            pairingID: "physical-mac\u{1F}default", endpointIDHex: "stable-peer",
            bindingID: "stable-binding", identityGeneration: 2
        )))
        #expect(entries.keys.contains(.init(
            pairingID: "physical-mac\u{1F}nightly", endpointIDHex: "nightly-peer",
            bindingID: "nightly-binding", identityGeneration: 3
        )))
        let stable = state.compatibilityEntry(pairingID: "physical-mac\u{1F}default")
        let nightly = state.compatibilityEntry(pairingID: "physical-mac\u{1F}nightly")
        #expect(stable.appVersion == "0.64.22")
        #expect(stable.isOutdated)
        #expect(stable.requiredVersionDisplay == "0.64.23")
        #expect(nightly.appVersion == "0.64.22-nightly.3439608067501")
        #expect(!nightly.isOutdated)
    }

    @Test
    func missingStableRecordCannotBorrowNightlyCompatibility() {
        let snapshot = snapshot(entries: ["nightly-peer": .init(
            deviceID: "physical-mac", status: "active", revoked: false,
            appVersion: "0.64.22-nightly.3439608067501", releaseTrack: "nightly"
        )])
        let state = MobileMacListAuthState()
        state.applyPolicyMinimumSupportedMacVersions(stable: "0.64.23", nightly: nil)
        state.replace(entriesByIdentity: MobileIrxRuntimeComposition.macListAuthEntries(from: snapshot))
        #expect(state.compatibilityEntry(pairingID: "physical-mac\u{1F}default").isOutdated)
        #expect(!state.compatibilityEntry(pairingID: "physical-mac\u{1F}nightly").isOutdated)
    }

    private func snapshot(entries: [String: IrxDeviceListEntry]) -> IrxDeviceListSnapshot {
        .init(entries: entries, rev: 1, issuedAt: .now, ttlSeconds: 300,
              receivedAtWall: .now, receivedAtMonotonic: .now)
    }
}
