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
            record(endpointID: "stable-peer", appVersion: "0.64.22",
                   recordID: "stable-binding", tag: "default", generation: 2),
            record(endpointID: "nightly-peer", appVersion: "0.64.22-nightly.3439608067501",
                   recordID: "nightly-binding", tag: "nightly", generation: 3),
        ]
        let snapshot = snapshot(records: reverseOrder ? records.reversed() : records)
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
        let snapshot = snapshot(records: [record(
            endpointID: "nightly-peer", appVersion: "0.64.22-nightly.3439608067501",
            recordID: "nightly-binding", tag: "nightly", generation: 3
        )])
        let state = MobileMacListAuthState()
        state.applyPolicyMinimumSupportedMacVersions(stable: "0.64.23", nightly: nil)
        state.replace(entriesByIdentity: MobileIrxRuntimeComposition.macListAuthEntries(from: snapshot))
        #expect(state.compatibilityEntry(pairingID: "physical-mac\u{1F}default").isOutdated)
        #expect(!state.compatibilityEntry(pairingID: "physical-mac\u{1F}nightly").isOutdated)
    }

    private func snapshot(records: [V2DeviceRecord]) -> V2Directory {
        let now = Int(Date().timeIntervalSince1970)
        return .init(devices: records, issuedAt: now, permissionExpiresAt: now + 300,
                     relayURLs: [], revision: 1, teamID: "team")
    }

    private func record(endpointID: String, appVersion: String, recordID: String,
                        tag: String, generation: Int) -> V2DeviceRecord {
        .init(descriptor: .init(endpointID: endpointID,
            identity: .init(appNamespace: "dev.cmux", buildTag: tag,
                deviceID: "physical-mac", environment: "staging", projectID: "cmux",
                teamID: "team", userID: "user"),
            identityGeneration: generation,
            metadata: .init(appVersion: appVersion, capabilities: [], displayName: "Mac",
                pairingEnabled: true, platform: .mac, relayURLs: [])),
            deviceRecordID: recordID, revision: 1, revoked: false)
    }
}
