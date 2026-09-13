import CMUXMobileCore
import CmuxIrohTransport
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The directory merge decides which Macs the Devices tab lists, which routes
/// it dials, and — the security-relevant part — whether a device is this
/// account's, since the viewer presents its bearer token only to those.
@Suite("Devices: directory merge")
struct DeviceDirectoryMergeTests {
    @Test("Account broker discovery includes enabled Macs outside the selected team", arguments: [true, false])
    func accountWideDiscovery(enabled: Bool) throws {
        let data = Data("""
        {"binding_id":"44444444-4444-4444-8444-444444444444",
         "device_id":"22222222-2222-2222-2222-222222222222",
         "app_instance_id":"55555555-5555-4555-8555-555555555555",
         "client_namespace":"mac:com.cmuxterm.app","tag":"default","platform":"mac",
         "display_name":"Studio","endpoint_id":"\(String(repeating: "ab", count: 32))",
         "identity_generation":1,"pairing_enabled":\(enabled),"capabilities":["cmux.irx.v1"],
         "path_hints":[],"last_seen_at":"2026-09-10T12:00:00Z"}
        """.utf8)
        let binding = try JSONDecoder().decode(CmxIrohBrokerBinding.self, from: data)
        let records = DeviceDirectoryMerge.merge(.init(
            authenticatedMacs: [binding], ownersKnown: true,
            selfInstance: selfInstance, currentUserID: "my-account", resolvedTeamID: "work-team"
        ))
        if enabled {
            let record = try #require(records.first)
            #expect(records.count == 1)
            #expect(record.deviceName == "Studio")
            #expect(record.accountTrust == .sameAccount)
            #expect(record.isDialable)
            #expect(record.routes.map(\.kind) == [.iroh])
        } else {
            #expect(records.isEmpty)
        }
    }

    private let selfID = "11111111-1111-1111-1111-111111111111"
    private let studioID = "22222222-2222-2222-2222-222222222222"
    private let laptopID = "33333333-3333-3333-3333-333333333333"

    private var selfInstance: SurfaceDeviceInstanceID {
        SurfaceDeviceInstanceID(deviceID: selfID, tag: "default")
    }

    private func route(_ id: String, port: Int = 51000, priority: Int = 10) throws -> CmxAttachRoute {
        try CmxAttachRoute(id: id, kind: .tailscale, endpoint: .hostPort(host: "100.64.0.9", port: port), priority: priority)
    }

    private func registryDevice(
        _ deviceID: String,
        name: String?,
        tags: [String] = ["default"],
        routes: [CmxAttachRoute] = [],
        platform: String = "mac",
        manual: Bool = false,
        lastSeenAt: Date? = nil
    ) -> DeviceRegistryDirectoryClient.Device {
        DeviceRegistryDirectoryClient.Device(
            deviceID: deviceID, platform: platform, displayName: name, isManual: manual, lastSeenAt: lastSeenAt,
            instances: tags.map { DeviceRegistryDirectoryClient.Instance(tag: $0, routes: routes, lastSeenAt: lastSeenAt) }
        )
    }

    private func presence(
        _ deviceID: String,
        tag: String = "default",
        online: Bool,
        name: String? = nil,
        routes: [CmxAttachRoute]? = nil,
        lastSeenAt: Double = 1_700_000_000_000,
        platform: String = "mac"
    ) -> (SurfaceDeviceInstanceID, DevicePresenceInstance) {
        let instance = DevicePresenceInstance(
            deviceId: deviceID, tag: tag, platform: platform, displayName: name, bundleId: "com.cmuxterm.app",
            online: online, lastSeenAt: lastSeenAt, routes: routes
        )
        return (instance.instanceID, instance)
    }

    private func record(
        _ instance: SurfaceDeviceInstanceID,
        name: String,
        online: Bool,
        paired: Bool = false,
        routes: [CmxAttachRoute] = [],
        lastSeenAt: Date? = nil,
        owner: String? = nil,
        trust: SurfaceDevicePresence.AccountTrust
    ) -> DeviceDirectoryRecord {
        DeviceDirectoryRecord(
            instance: instance, deviceName: name, platform: "mac", bundleID: nil,
            presenceState: online ? .online : .offline, isPaired: paired, wasDiscovered: true,
            lastSeenAt: lastSeenAt, routes: routes, ownerUserID: owner, accountTrust: trust
        )
    }

    private func paired(
        _ instance: SurfaceDeviceInstanceID,
        name: String,
        routes: [CmxAttachRoute],
        lastSeenAt: Date? = nil
    ) -> DevicePairedDevice {
        DevicePairedDevice(instance: instance, displayName: name, routes: routes, lastSeenAt: lastSeenAt)
    }

    @Test("Unpair removes a local-only Mac and its routes without removing another build's grant")
    func unpairRemovesLocalOnlyRecord() throws {
        let studio = SurfaceDeviceInstanceID(deviceID: studioID, tag: "default")
        let taggedStudio = SurfaceDeviceInstanceID(deviceID: studioID, tag: "dev")
        let savedRoute = try route("paired")
        let mainPair = paired(studio, name: "Studio", routes: [savedRoute])
        let devPair = paired(taggedStudio, name: "Studio Dev", routes: [savedRoute])
        let before = DeviceDirectoryMerge.merge(.init(
            paired: [mainPair, devPair], selfInstance: selfInstance, currentUserID: "user_a"
        ))
        #expect(before.map(\.instance) == [studio])
        let after = DeviceDirectoryMerge.merge(.init(
            paired: [devPair], previous: before, selfInstance: selfInstance, currentUserID: "user_a"
        ))
        #expect(after.isEmpty)
        let refreshed = DeviceDirectoryMerge.merge(.init(
            paired: [devPair], previous: after,
            selfInstance: SurfaceDeviceInstanceID(deviceID: selfID, tag: "dev"), currentUserID: "user_a"
        ))
        #expect(refreshed.map(\.instance) == [taggedStudio])
    }

    @Test("Unpair retains a discovered Mac but drops routes supplied only by its revoked grant")
    func unpairRetainsDiscoveryWithoutRevokedRoutes() throws {
        let studio = SurfaceDeviceInstanceID(deviceID: studioID, tag: "default")
        let discovered = registryDevice(studioID, name: "Studio")
        let before = DeviceDirectoryMerge.merge(.init(
            registry: [discovered], paired: [paired(studio, name: "Studio", routes: [try route("paired")])],
            selfInstance: selfInstance, currentUserID: "user_a"
        ))
        let after = DeviceDirectoryMerge.merge(.init(
            registry: [discovered], previous: before, selfInstance: selfInstance, currentUserID: "user_a"
        ))
        let remaining = try #require(after.first)
        #expect(!remaining.isPaired)
        #expect(remaining.routes.isEmpty)
        #expect(!remaining.isDialable)
        let offline = DeviceDirectoryMerge.merge(.init(
            previous: after, selfInstance: selfInstance, currentUserID: "user_a"
        ))
        #expect(offline.map(\.instance) == [studio])
    }

    @Test("Registry and presence union into one record per instance, never listing this Mac")
    func unionExcludesSelf() throws {
        let liveRoute = try route("live")
        let staleRoute = try route("stale", port: 50000)
        let (studioKey, studio) = presence(studioID, online: true, name: "Studio", routes: [liveRoute])
        let (selfKey, selfPresence) = presence(selfID, online: true, name: "This Mac")
        let records = DeviceDirectoryMerge.merge(DeviceDirectoryMerge.Input(
            registry: [
                registryDevice(studioID, name: "Studio (registry)", routes: [staleRoute]),
                registryDevice(laptopID, name: "Laptop", tags: ["default", "issue-8001"], routes: [staleRoute]),
                registryDevice(selfID, name: "This Mac"),
            ],
            presence: [studioKey: studio, selfKey: selfPresence],
            presenceLive: true,
            selfInstance: selfInstance,
            currentUserID: "user_a",
            resolvedTeamID: nil
        ))
        #expect(records.map(\.instance.wireValue) == [
            "device:\(studioID)@default",
            "device:\(laptopID)@default",
        ])
        let studioRecord = try #require(records.first)
        #expect(studioRecord.isOnline)
        #expect(studioRecord.deviceName == "Studio", "the live presence name wins over the registry's")
        #expect(studioRecord.routes.map(\.id) == ["live", "stale"], "live routes lead the registry candidates")
        #expect(studioRecord.bundleID == "com.cmuxterm.app")
        #expect(studioRecord.presence.isOnline)
        #expect(records[1].isOnline == false)
        #expect(records[1].presenceState == .offline, "absent from a live presence snapshot means offline")
        #expect(records[1].isPaired == false)
        #expect(records[1].routes.map(\.id) == ["stale"], "an offline instance keeps the registry's durable routes")
    }

    @Test("Dev directories show only the same tag, nightly and stable across every source", arguments: [
        ("default", ["default"]),
        ("nightly", ["nightly"]),
        ("rc", ["rc"]),
        ("staging", ["staging"]),
        ("issue-8001", ["default", "issue-8001", "nightly"]),
        ("dev", ["default", "dev", "nightly"]),
    ])
    func matchingBuildInstances(viewerTag: String, visibleTags: [String]) throws {
        let tags = ["default", "nightly", "dev", "issue-8001", "unrelated-dev", "rc", "staging"]
        let saved = try route("saved")
        let live = Dictionary(uniqueKeysWithValues: tags.flatMap { tag in
            [presence(studioID, tag: tag, online: true, name: "Mac mini"),
             presence(selfID, tag: tag, online: true, name: "This Mac")]
        })
        let instances = tags.map { SurfaceDeviceInstanceID(deviceID: studioID, tag: $0) }
        let records = DeviceDirectoryMerge.merge(.init(
            registry: [
                registryDevice(studioID.uppercased(), name: "Old name", tags: tags + [viewerTag]),
                registryDevice(laptopID, name: "Mac mini", tags: tags),
            ],
            presence: live,
            presenceLive: true,
            paired: instances.map { paired($0, name: "Saved name", routes: [saved]) },
            previous: instances.map { record($0, name: "Remembered", online: false, trust: .sameAccount) },
            selfInstance: SurfaceDeviceInstanceID(deviceID: selfID, tag: viewerTag),
            currentUserID: "user_a"
        ))
        let expectedInstances = [studioID, laptopID].flatMap { deviceID in
            visibleTags.map { SurfaceDeviceInstanceID(deviceID: deviceID, tag: $0) }
        }
        #expect(records.map(\.instance) == expectedInstances)
        #expect(records.map(\.deviceName) == Array(repeating: "Mac mini", count: expectedInstances.count), "Distinct Macs with the same name must remain reachable")
        #expect(records.first?.routes == [saved])

        let remembered = DeviceDirectoryMerge.merge(.init(
            previous: records + instances.map { record($0, name: "Stale", online: false, trust: .sameAccount) },
            selfInstance: SurfaceDeviceInstanceID(deviceID: selfID, tag: viewerTag),
            currentUserID: "user_a"
        ))
        #expect(Set(remembered.map(\.instance)) == Set(records.map(\.instance)))
        #expect(remembered.count == expectedInstances.count, "Reconnects cannot resurrect other builds or duplicate a device")
    }

    @Test("Previous records survive presence forgetting them; manual remotes and phones never appear")
    func previousRecordsAndFilters() throws {
        let old = try route("old")
        let laptop = SurfaceDeviceInstanceID(deviceID: laptopID, tag: "default")
        let previous = record(laptop, name: "Laptop", online: true, routes: [old], lastSeenAt: Date(timeIntervalSince1970: 1_000), owner: "user_a", trust: .sameAccount)
        let (phoneKey, phone) = presence("44444444-4444-4444-4444-444444444444", online: true, name: "iPhone", platform: "ios")
        let records = DeviceDirectoryMerge.merge(DeviceDirectoryMerge.Input(
            registry: [
                registryDevice("manual-1", name: "Manual box", manual: true),
                registryDevice("55555555-5555-5555-5555-555555555555", name: "Phone", platform: "ios"),
            ],
            presence: [phoneKey: phone],
            presenceLive: true,
            previous: [previous],
            selfInstance: selfInstance,
            currentUserID: "user_a",
            resolvedTeamID: nil
        ))
        #expect(records.count == 1)
        let remembered = try #require(records.first)
        #expect(remembered.instance == laptop)
        #expect(remembered.isOnline == false, "a device presence no longer reports is offline, not gone")
        #expect(remembered.routes.map(\.id) == ["old"])
        #expect(remembered.lastSeenAt == previous.lastSeenAt)
        #expect(remembered.deviceName == "Laptop")
        #expect(remembered.ownerUserID == "user_a")
    }

    @Test("Account trust: owner pins decide, a personal team implies this account, a team without pins is unknown")
    func accountTrust() {
        let (studioKey, studio) = presence(studioID, online: true)
        let (laptopKey, laptop) = presence(laptopID, online: true)
        func trust(
            owners: [String: String],
            ownersKnown: Bool,
            teamID: String?,
            previous: [DeviceDirectoryRecord] = []
        ) -> [SurfaceDeviceInstanceID: SurfaceDevicePresence.AccountTrust] {
            let records = DeviceDirectoryMerge.merge(DeviceDirectoryMerge.Input(
                presence: [studioKey: studio, laptopKey: laptop],
                owners: owners,
                ownersKnown: ownersKnown,
                previous: previous,
                selfInstance: selfInstance,
                currentUserID: "user_a",
                resolvedTeamID: teamID
            ))
            return Dictionary(uniqueKeysWithValues: records.map { ($0.instance, $0.accountTrust) })
        }
        // Team scope with the owner snapshot delivered: pins decide, a missing pin is unknown.
        let pinned = trust(owners: [studioID: "user_a", laptopID: "user_b"], ownersKnown: true, teamID: "team_x")
        #expect(pinned[studioKey] == .sameAccount)
        #expect(pinned[laptopKey] == .otherAccount)
        #expect(trust(owners: [:], ownersKnown: true, teamID: "team_x")[studioKey] == .unknown)
        // Personal scope: every device on the account is this account's.
        #expect(trust(owners: [:], ownersKnown: false, teamID: nil)[laptopKey] == .sameAccount)
        #expect(trust(owners: [:], ownersKnown: false, teamID: "user_a")[laptopKey] == .sameAccount)
        // A pin for another user overrides even the personal scope.
        #expect(trust(owners: [laptopID: "user_b"], ownersKnown: true, teamID: nil)[laptopKey] == .otherAccount)
        // Team scope before the owner snapshot lands: keep what the previous merge knew.
        let remembered = record(laptopKey, name: "Laptop", online: false, owner: "user_b", trust: .otherAccount)
        #expect(trust(owners: [:], ownersKnown: false, teamID: "team_x", previous: [remembered])[laptopKey] == .otherAccount)
        #expect(trust(owners: [:], ownersKnown: false, teamID: "team_x")[studioKey] == .unknown)
    }

    @Test("A complete owner snapshot supersedes remembered ownership")
    func completeOwnershipSnapshotRevokesRememberedOwner() throws {
        let (key, live) = presence(studioID, online: true, routes: [try route("ts")])
        let previous = record(key, name: "Studio", online: true, routes: [try route("ts")], owner: "user_a", trust: .sameAccount)
        let records = DeviceDirectoryMerge.merge(.init(
            presence: [key: live], ownersKnown: true, previous: [previous],
            selfInstance: selfInstance, currentUserID: "user_a", resolvedTeamID: "team_x"
        ))
        let current = try #require(records.first)
        #expect(current.ownerUserID == nil)
        #expect(current.accountTrust == .unknown)
        #expect(!current.isDialable)
    }

    @Test("Dialable means routed, this account's, and paired or reported online")
    func dialable() throws {
        let tailscale = try route("ts")
        let studio = SurfaceDeviceInstanceID(deviceID: studioID, tag: "default")
        #expect(record(studio, name: "Studio", online: true, routes: [tailscale], trust: .sameAccount).isDialable)
        #expect(!record(studio, name: "Studio", online: false, routes: [tailscale], trust: .sameAccount).isDialable)
        #expect(record(studio, name: "Studio", online: false, paired: true, routes: [tailscale], trust: .sameAccount).isDialable, "presence never suppresses a saved pairing")
        #expect(!record(studio, name: "Studio", online: true, routes: [], trust: .sameAccount).isDialable)
        #expect(!record(studio, name: "Studio", online: true, paired: true, routes: [], trust: .sameAccount).isDialable)
        #expect(!record(studio, name: "Studio", online: true, routes: [tailscale], trust: .otherAccount).isDialable)
        #expect(!record(studio, name: "Studio", online: true, routes: [tailscale], trust: .unknown).isDialable)
    }

    @Test("A paired Mac is listed local-first: no registry, no presence, still this account's and dialable")
    func pairedLocalFirst() throws {
        let saved = try route("saved", port: 52000, priority: 20)
        let live = try route("live", port: 51000, priority: 1)
        let studio = SurfaceDeviceInstanceID(deviceID: studioID, tag: "default")
        let offlineWorld = DeviceDirectoryMerge.merge(DeviceDirectoryMerge.Input(
            paired: [paired(studio, name: "Studio (paired)", routes: [saved], lastSeenAt: Date(timeIntervalSince1970: 10))],
            selfInstance: selfInstance,
            currentUserID: "user_a",
            resolvedTeamID: "team_x"
        ))
        let record = try #require(offlineWorld.first)
        #expect(offlineWorld.count == 1)
        #expect(record.instance == studio)
        #expect(record.isPaired)
        #expect(record.presenceState == .unknown, "no presence stream yet: unknown, not offline")
        #expect(record.accountTrust == .sameAccount, "pairing proved the account even without owner pins")
        #expect(record.routes.map(\.id) == ["saved"])
        #expect(record.deviceName == "Studio (paired)")
        #expect(record.lastSeenAt == Date(timeIntervalSince1970: 10))
        #expect(record.isDialable)

        // Presence live and silent about it: offline label, still dialable.
        let (otherKey, other) = presence(laptopID, online: true, name: "Laptop")
        let quiet = DeviceDirectoryMerge.merge(DeviceDirectoryMerge.Input(
            presence: [otherKey: other], presenceLive: true,
            paired: [paired(studio, name: "Studio", routes: [saved])],
            selfInstance: selfInstance, currentUserID: "user_a", resolvedTeamID: nil
        ))
        let quietStudio = try #require(quiet.first { $0.instance == studio })
        #expect(quietStudio.presenceState == .offline)
        #expect(quietStudio.isDialable)
        #expect(quiet.map(\.deviceName) == ["Laptop", "Studio"], "online rows sort before offline ones")

        // Presence online with a live route: the saved route still leads.
        let (studioKey, studioPresence) = presence(studioID, online: true, name: "Studio", routes: [live])
        let online = DeviceDirectoryMerge.merge(DeviceDirectoryMerge.Input(
            presence: [studioKey: studioPresence], presenceLive: true,
            paired: [paired(studio, name: "Studio", routes: [saved])],
            selfInstance: selfInstance, currentUserID: "user_a", resolvedTeamID: nil
        ))
        #expect(online.first?.routes.map(\.id) == ["saved", "live"])
        #expect(online.first?.presenceState == .online)
    }

    @Test("Sorting ranks online, then unknown, then offline")
    func presenceRank() {
        let studio = SurfaceDeviceInstanceID(deviceID: studioID, tag: "default")
        let (laptopKey, laptop) = presence(laptopID, online: false, name: "Laptop")
        let records = DeviceDirectoryMerge.merge(DeviceDirectoryMerge.Input(
            presence: [laptopKey: laptop],
            paired: [paired(studio, name: "Zed", routes: [])],
            selfInstance: selfInstance, currentUserID: "user_a", resolvedTeamID: nil
        ))
        #expect(records.map(\.presenceState) == [.unknown, .offline])
        #expect(records.map(\.deviceName) == ["Zed", "Laptop"])
    }

    @Test("Online devices sort first, then by name, so presence flips never shuffle the offline rows")
    func ordering() {
        let (alphaKey, alpha) = presence(studioID, online: false, name: "Alpha")
        let (zuluKey, zulu) = presence(laptopID, online: true, name: "Zulu")
        let (bravoKey, bravo) = presence("55555555-5555-5555-5555-555555555555", online: false, name: "bravo")
        let records = DeviceDirectoryMerge.merge(DeviceDirectoryMerge.Input(
            presence: [alphaKey: alpha, zuluKey: zulu, bravoKey: bravo],
            selfInstance: selfInstance,
            currentUserID: "user_a",
            resolvedTeamID: nil
        ))
        #expect(records.map(\.deviceName) == ["Zulu", "Alpha", "bravo"])
    }

    @Test("lastSeenAt is the freshest source, with presence milliseconds converted to seconds")
    func lastSeen() {
        let (key, live) = presence(studioID, online: false, lastSeenAt: 1_700_000_000_000)
        let older = Date(timeIntervalSince1970: 1_600_000_000)
        let records = DeviceDirectoryMerge.merge(DeviceDirectoryMerge.Input(
            registry: [registryDevice(studioID, name: "Studio", lastSeenAt: older)],
            presence: [key: live],
            selfInstance: selfInstance,
            currentUserID: "user_a",
            resolvedTeamID: nil
        ))
        #expect(records.first?.lastSeenAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(records.first?.deviceName == "Studio", "a presence row without a name falls back to the registry")
    }

    @Test("The row's link state ranks presence, account, pairing, then the reconnect phase")
    @MainActor
    func providerLinkState() throws {
        let tailscale = try route("ts")
        let studio = SurfaceDeviceInstanceID(deviceID: studioID, tag: "default")
        func state(
            online: Bool = true,
            trust: SurfaceDevicePresence.AccountTrust = .sameAccount,
            routes: [CmxAttachRoute]? = nil,
            phase: DeviceLinkReconnectPolicy.Phase = .idle,
            lastFailure: String? = nil,
            needsAuthorization: Bool = false
        ) -> (linkState: SurfaceLinkState, linkError: String?) {
            DeviceSurfaceProvider.linkState(
                record: record(studio, name: "Studio", online: online, routes: routes ?? [tailscale], trust: trust),
                phase: phase, lastFailure: lastFailure, needsAuthorization: needsAuthorization
            )
        }
        #expect(state(online: false, phase: .connected).linkState == .connected, "a live link outranks stale presence")
        #expect(state(online: false, phase: .connecting(attempt: 2)).linkState == .offline, "a paired Mac presence reports offline keeps dialing quietly")
        #expect(state(trust: .otherAccount, phase: .connected).linkState == .unavailable)
        #expect(state(phase: .connected).linkState == .connected)
        #expect(state(phase: .connecting(attempt: 1)).linkState == .connecting)
        #expect(state(phase: .waiting(attempt: 1, delay: .seconds(1))).linkState == .connecting)
        #expect(state(phase: .waiting(attempt: 2, delay: .seconds(2)), lastFailure: "Relay unavailable").linkError == "Relay unavailable")
        #expect(state(phase: .connecting(attempt: 3), lastFailure: "Relay unavailable").linkError == "Relay unavailable")
        let blocked = state(phase: .blocked(reason: "nope"))
        #expect(blocked.linkState == .error)
        #expect(blocked.linkError == "nope")
        #expect(state(routes: []).linkError == "This Mac has not published a route yet.")
        #expect(state(trust: .unknown).linkState == .unavailable)
        let unpaired = state(needsAuthorization: true)
        #expect(unpaired.linkState == .unavailable)
        #expect(unpaired.linkError == "Pair this Mac in Settings \u{203A} Computers to connect.")
        #expect(state(lastFailure: "boom").linkError == "boom")
    }

    @Test("A device nobody names shows its UUID prefix")
    func unnamedDevice() {
        let (key, live) = presence(studioID, online: true)
        let records = DeviceDirectoryMerge.merge(DeviceDirectoryMerge.Input(
            presence: [key: live], selfInstance: selfInstance, currentUserID: "user_a", resolvedTeamID: nil
        ))
        #expect(records.first?.deviceName == "22222222")
    }
}
