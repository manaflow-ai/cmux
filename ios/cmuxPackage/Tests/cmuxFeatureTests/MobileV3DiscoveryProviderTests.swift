import CMUXMobileCore
import CmuxV3Transport
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
