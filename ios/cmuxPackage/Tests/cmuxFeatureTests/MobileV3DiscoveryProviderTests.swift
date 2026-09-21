import CMUXMobileCore
import CmuxV3Transport
import CmuxMobileShell
import Foundation
import Testing
@testable import cmuxFeature

@Test
func v3DirectoryProjectionDropsInactiveAndAddresslessDevices() throws {
    let active = CmxV3DirectoryDevice(
        peerID: "12D3KooWActive",
        deviceID: "mac-active",
        addresses: ["/ip4/203.0.113.10/tcp/4001/p2p/12D3KooWActive"],
        active: true,
        tags: [],
        lease: CmxV3DirectoryLease(renewEverySeconds: 30)
    )
    let inactive = CmxV3DirectoryDevice(
        peerID: "12D3KooWInactive",
        deviceID: "mac-inactive",
        addresses: ["/ip4/203.0.113.11/tcp/4001/p2p/12D3KooWInactive"],
        active: false,
        tags: [],
        lease: CmxV3DirectoryLease(renewEverySeconds: 30)
    )
    let empty = CmxV3DirectoryDevice(
        peerID: "12D3KooWEmpty",
        deviceID: "mac-empty",
        addresses: [],
        active: true,
        tags: [],
        lease: CmxV3DirectoryLease(renewEverySeconds: 30)
    )
    let directory = CmxV3Directory(team: "team", revision: 3, devices: [active, inactive, empty])
    let candidates = MobileV3DiscoveryProvider.candidates(from: directory, preferredTag: "default", now: Date(timeIntervalSince1970: 100))
    #expect(candidates.count == 1)
    #expect(candidates[0].deviceID == "mac-active")
    #expect(candidates[0].routes.first?.kind == .v3)
    #expect(candidates[0].routes.first?.endpoint != nil)
}


@Test
func v3DirectoryProjectionPublishesRoutesToSharedCatalog() async throws {
    let device = CmxV3DirectoryDevice(
        peerID: "12D3KooWCatalog",
        deviceID: "mac-catalog",
        addresses: ["/ip4/203.0.113.12/tcp/4001/p2p/12D3KooWCatalog"],
        active: true,
        tags: [],
        lease: CmxV3DirectoryLease(renewEverySeconds: 10)
    )
    let directory = CmxV3Directory(team: "team", revision: 1, devices: [device])
    let catalog = MobileIrohRouteCatalog()
    await catalog.activate(scope: 1)
    #expect(await catalog.replaceV3(with: directory, scope: 1))
    let routes = await catalog.routes(forKnownMacDeviceID: "mac-catalog", instanceTag: "default")
    #expect(routes.count == 1)
    #expect(routes[0].kind == .v3)
}

@Test
func v3DirectoryProjectionRequiresMacMetadataAndPreservesActualBuildIdentity() async throws {
    func device(_ id: String, platform: String = "mac", tag: String = "v3dog", pairing: Bool = true, namespace: String = "mac:com.cmuxterm.app.debug.v3dog") throws -> CmxV3DirectoryDevice {
        let json: [String: Any] = [
            "peer_id": "12D3KooW\(id)", "device_id": id,
            "addresses": ["/ip4/203.0.113.10/tcp/4001"], "active": true,
            "metadata": ["platform": platform, "instance_tag": tag,
                         "display_name": "Office Mac", "pairing_enabled": pairing,
                         "client_namespace": namespace]
        ]
        return try JSONDecoder().decode(CmxV3DirectoryDevice.self, from: JSONSerialization.data(withJSONObject: json))
    }
    let directory = CmxV3Directory(team: "team", revision: 1, devices: [
        try device("host"), try device("phone", platform: "ios", pairing: false),
        try device("disabled", pairing: false), try device("other", tag: "other"),
        try device("release", tag: "default", namespace: "mac:com.cmuxterm.app")
    ])
    let policy = MobileMacBuildCompatibilityPolicy.development(expectedInstanceTag: "v3dog")
    let candidates = MobileV3DiscoveryProvider.candidates(from: directory, preferredTag: "v3dog", compatibleWith: policy)
    #expect(candidates.map(\.deviceID) == ["host"])
    #expect(candidates.first?.displayName == "Office Mac")
    #expect(candidates.first?.instanceTag == "v3dog")
    #expect(candidates.first?.clientNamespace == "mac:com.cmuxterm.app.debug.v3dog")
    let catalog = MobileIrohRouteCatalog()
    await catalog.activate(scope: 1)
    #expect(await catalog.replaceV3(with: directory, scope: 1, compatibleWith: policy))
    #expect(await catalog.routes(forKnownMacDeviceID: "host", instanceTag: "v3dog").count == 1)
    #expect(await catalog.routes(forKnownMacDeviceID: "host", instanceTag: "default").isEmpty)
    #expect(await catalog.routes(forKnownMacDeviceID: "phone", instanceTag: "v3dog").isEmpty)
    #expect(await catalog.routes(forKnownMacDeviceID: "other", instanceTag: "other").isEmpty)
}

@Test
func v3DirectoryWithoutMetadataIsNotAssumedToBeAMac() throws {
    let device = try JSONDecoder().decode(CmxV3DirectoryDevice.self, from: Data(#"{"peer_id":"12D3KooWLegacy","device_id":"legacy","addresses":["/ip4/203.0.113.10/tcp/4001"],"active":true}"#.utf8))
    let directory = CmxV3Directory(team: "team", revision: 1, devices: [device])
    #expect(MobileV3DiscoveryProvider.candidates(from: directory, preferredTag: "default", compatibleWith: .official).isEmpty)
}
