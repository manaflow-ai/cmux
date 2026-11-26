import CMUXMobileCore
import CmuxIrohTransport
import CmuxIrxTransport
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Fixtures for the per-user (cross-team) Mac directory. This Mac is `self`
/// in team A; its other Mac `peer` selected team B, so team A can only hold a
/// stale key for it while the account directory names the current one.
private enum AccountFixture {
    static let selfKey = String(repeating: "a", count: 64)
    static let peerKey = String(repeating: "b", count: 64)
    static let staleKey = String(repeating: "c", count: 64)
    static let phoneKey = String(repeating: "d", count: 64)
    static let now = Date(timeIntervalSince1970: 1500)

    static func identity(device: String, team: String, user: String = "user", tag: String = "default",
                         namespace: String = "com.cmuxterm.app", environment: String = "production") -> V2Identity {
        V2Identity(appNamespace: namespace, buildTag: tag, deviceID: device, environment: environment,
            projectID: "project", teamID: team, userID: user)
    }

    static func record(_ identity: V2Identity, endpoint: String, platform: V2Platform = .mac,
                       capabilities: [String] = ["irx-v2", "cmux.mac-devices.v1", "cmux.mac-host.v1"],
                       revoked: Bool = false, id: String? = nil) -> V2DeviceRecord {
        V2DeviceRecord(descriptor: V2DeviceDescriptor(endpointID: endpoint, identity: identity, identityGeneration: 1,
            metadata: V2DeviceMetadata(appVersion: "1", capabilities: capabilities, displayName: identity.deviceID,
                pairingEnabled: platform == .ios, platform: platform, relayURLs: ["https://relay.example"])),
            deviceRecordID: id ?? (identity.teamID + "-" + identity.deviceID), revision: 1, revoked: revoked)
    }

    static let selfIdentity = identity(device: "self", team: "A")
    static let peerIdentity = identity(device: "peer", team: "B")

    static func hostRecord(capabilities: [String] = ["irx-v2", "cmux.mac-devices.v1", "cmux.mac-host.v1"],
                           revoked: Bool = false) -> V2DeviceRecord {
        record(selfIdentity, endpoint: selfKey, capabilities: capabilities, revoked: revoked)
    }

    static func cache(host: V2DeviceRecord = hostRecord(), teamDevices: [V2DeviceRecord] = [],
                      teamInbound: [V2InboundPeerPermission] = [], revoked: Bool = false) -> V2CachedState {
        var cache = V2CachedState(identity: selfIdentity)
        cache.device = host
        cache.authorityRevoked = revoked
        cache.ticket = V2Ticket(expiresAt: 2000, refreshAfter: 1700, token: "ticket")
        cache.directory = V2Directory(devices: teamDevices, inboundPeers: teamInbound, issuedAt: 1000,
            permissionExpiresAt: 2000, relayURLs: ["https://relay.example"], revision: 1,
            rules: [DeviceLinkControlPlaneRules.macPeerInbound], teamID: "A")
        return cache
    }

    static func account(macs: [V2DeviceRecord] = [record(peerIdentity, endpoint: peerKey)],
                        inbound: [V2InboundPeerPermission] = [],
                        revision: Int = 1, issuedAt: Int = 1000, expiresAt: Int = 2000,
                        rules: [String] = [AccountMacDirectory.accountPeerRule], userID: String = "user",
                        requester: V2DeviceDescriptor = hostRecord().descriptor) -> AccountMacDirectorySnapshot {
        AccountMacDirectorySnapshot(directory: AccountMacDirectory(userID: userID, revision: revision, macs: macs,
            inboundMacs: inbound, relayURLs: ["https://relay.example"], issuedAt: issuedAt,
            permissionExpiresAt: expiresAt, rules: rules), requester: requester)
    }

    static func inbound(_ record: V2DeviceRecord, expiresAt: Int = 2000) -> V2InboundPeerPermission {
        V2InboundPeerPermission(device: record, permissionExpiresAt: expiresAt)
    }
}

/// A manually advanced monotonic clock for lease tests.
private final class TestClock: Sendable {
    let start = ContinuousClock.now
    private let offset = LockedBox(0.0)
    var now: ContinuousClock.Instant { start.advanced(by: .seconds(offset.value)) }
    func advance(_ seconds: Double) { offset.value += seconds }
}

private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

@Suite("Devices: account Mac peer authorization")
struct AccountMacPeerAuthorizationTests {
    fileprivate typealias F = AccountFixture

    private func resolve(_ account: AccountMacDirectorySnapshot?, cache: V2CachedState = F.cache(),
                         deviceID: String = "peer", tag: String = "default",
                         endpoint: String = F.peerKey, now: Date = F.now) throws -> V2DeviceRecord {
        try IrxAccountMacPeerAuthorization(deviceID: deviceID, tag: tag, endpointID: endpoint)
            .resolve(account: account, cache: cache, localIdentity: F.selfIdentity, now: now)
    }

    @Test("Allows the same user's Mac that selected another team")
    func allowsAcrossTeams() throws {
        let peer = try resolve(F.account())
        #expect(peer.descriptor.endpointID == F.peerKey)
        #expect(peer.descriptor.identity.teamID == "B")
        // The team authority alone refuses it: different team.
        #expect(throws: IrxMacPeerAuthorization.Failure.self) {
            try IrxMacPeerAuthorization(deviceID: "peer", tag: "default", endpointID: F.peerKey)
                .resolve(cache: F.cache(teamDevices: [F.account().directory.macs[0]]),
                    localIdentity: F.selfIdentity, now: F.now)
        }
    }

    enum Rejection: String, CaseIterable, Sendable {
        case otherUser, otherNamespace, otherEnvironment, otherTag, expired, notYetIssued, missingRule,
             missingHost, selfDevice, phone, revokedPeer, revokedLocal, localAuthorityRevoked,
             otherRequester, directoryOfOtherUser, missingDirectory, unknownEndpoint, sameTeam
    }

    @Test("Rejects every Mac outside the same-user, same-build scope", arguments: Rejection.allCases)
    func rejects(_ rejection: Rejection) {
        var account = F.account()
        var cache = F.cache()
        var deviceID = "peer"
        var tag = "default"
        var endpoint = F.peerKey
        var now = F.now
        func peer(_ identity: V2Identity, platform: V2Platform = .mac, capabilities: [String]? = nil,
                  revoked: Bool = false) -> AccountMacDirectorySnapshot {
            F.account(macs: [capabilities.map {
                F.record(identity, endpoint: F.peerKey, platform: platform, capabilities: $0, revoked: revoked)
            } ?? F.record(identity, endpoint: F.peerKey, platform: platform, revoked: revoked)])
        }
        let expected: IrxMacPeerAuthorization.Failure
        switch rejection {
        case .otherUser:
            account = peer(F.identity(device: "peer", team: "B", user: "someone-else")); expected = .identityMismatch
        case .otherNamespace:
            account = peer(F.identity(device: "peer", team: "B", namespace: "com.cmuxterm.app.nightly")); expected = .identityMismatch
        case .otherEnvironment:
            account = peer(F.identity(device: "peer", team: "B", environment: "development")); expected = .identityMismatch
        case .otherTag:
            tag = "other"; expected = .identityMismatch
        case .expired:
            now = Date(timeIntervalSince1970: 2000); expected = .staleDirectory
        case .notYetIssued:
            now = Date(timeIntervalSince1970: 999); expected = .staleDirectory
        case .missingRule:
            account = F.account(rules: []); expected = .staleDirectory
        case .missingHost:
            account = peer(F.peerIdentity, capabilities: ["irx-v2", "cmux.mac-devices.v1"]); expected = .notDiscoverable
        case .selfDevice:
            account = peer(F.identity(device: "self", team: "B")); deviceID = "self"; expected = .identityMismatch
        case .phone:
            account = peer(F.peerIdentity, platform: .ios); expected = .identityMismatch
        case .revokedPeer:
            account = peer(F.peerIdentity, revoked: true); expected = .revoked
        case .revokedLocal:
            cache = F.cache(host: F.hostRecord(revoked: true)); expected = .revoked
        case .localAuthorityRevoked:
            cache = F.cache(revoked: true); expected = .revoked
        case .otherRequester:
            // Fetched while this Mac was in another team (or under an older key).
            account = F.account(requester: F.record(F.identity(device: "self", team: "Z"), endpoint: F.staleKey).descriptor)
            expected = .staleDirectory
        case .directoryOfOtherUser:
            account = F.account(userID: "someone-else"); expected = .staleDirectory
        case .missingDirectory:
            expected = .staleDirectory
        case .unknownEndpoint:
            endpoint = F.staleKey; expected = .unavailable
        case .sameTeam:
            // Same-team Macs are the team directory's alone.
            account = peer(F.identity(device: "peer", team: "A")); expected = .identityMismatch
        }
        let snapshot: AccountMacDirectorySnapshot? = rejection == .missingDirectory ? nil : account
        #expect(throws: expected) {
            try resolve(snapshot, cache: cache, deviceID: deviceID, tag: tag, endpoint: endpoint, now: now)
        }
    }
}

@Suite("Devices: account Mac admission")
struct AccountMacAdmissionTests {
    fileprivate typealias F = AccountFixture

    private func authority(clock: TestClock = TestClock()) throws -> V2AccountMacAdmissionAuthority {
        try V2AccountMacAdmissionAuthority(host: F.hostRecord().descriptor,
            wallNow: { F.now }, monotonicNow: { clock.now })
    }

    @Test("Admits a same-user Mac from another team with Mac discovery opted in")
    func admitsCrossTeamMac() throws {
        let admission = try authority()
        let peer = F.record(F.peerIdentity, endpoint: F.peerKey)
        admission.apply(account: F.account(inbound: [F.inbound(peer)]), hostRecord: F.hostRecord())
        let admitted = try #require(admission.authorizedPeer(endpointID: F.peerKey))
        #expect(admitted.bindingID == peer.deviceRecordID)
        #expect(try admission.judgment()(nil, F.peerKey) == admitted)
    }

    @Test("Never admits a phone row, whatever it claims", arguments: [
        ["cmux.mac-devices.v1"], ["cmux.mac-devices.v1", "cmux.mac-host.v1"], ["irx-v2"],
    ])
    func neverAdmitsPhones(capabilities: [String]) throws {
        let admission = try authority()
        let phone = F.record(F.identity(device: "phone", team: "B"), endpoint: F.phoneKey,
            platform: .ios, capabilities: capabilities)
        admission.apply(account: F.account(inbound: [F.inbound(phone)]), hostRecord: F.hostRecord())
        #expect(admission.authorizedPeer(endpointID: F.phoneKey) == nil)
        #expect(throws: IrxAdmissionDenied(code: .invalidGrant)) { try admission.judgment()(nil, F.phoneKey) }
    }

    enum Rejection: String, CaseIterable, Sendable {
        case hostWithoutMacHost, hostRevoked, otherUser, otherNamespace, otherTag, otherEnvironment,
             peerWithoutMacDevices, revokedPeer, selfDevice, missingRule, otherRequester, expiredLease, duplicateEndpoint,
             sameTeam
    }

    @Test("Refuses every row outside the host opt-in and same-user, same-build scope", arguments: Rejection.allCases)
    func refuses(_ rejection: Rejection) throws {
        let admission = try authority()
        var host = F.hostRecord()
        var peers = [F.record(F.peerIdentity, endpoint: F.peerKey)]
        var rules = [AccountMacDirectory.accountPeerRule]
        var requester = F.hostRecord().descriptor
        var expiresAt = 2000
        switch rejection {
        case .hostWithoutMacHost: host = F.hostRecord(capabilities: ["irx-v2", "cmux.mac-devices.v1"])
        case .hostRevoked: host = F.hostRecord(revoked: true)
        case .otherUser: peers = [F.record(F.identity(device: "peer", team: "B", user: "other"), endpoint: F.peerKey)]
        case .otherNamespace: peers = [F.record(F.identity(device: "peer", team: "B", namespace: "other"), endpoint: F.peerKey)]
        case .otherTag: peers = [F.record(F.identity(device: "peer", team: "B", tag: "other"), endpoint: F.peerKey)]
        case .otherEnvironment: peers = [F.record(F.identity(device: "peer", team: "B", environment: "staging"), endpoint: F.peerKey)]
        case .peerWithoutMacDevices: peers = [F.record(F.peerIdentity, endpoint: F.peerKey, capabilities: ["irx-v2", "cmux.mac-host.v1"])]
        case .revokedPeer: peers = [F.record(F.peerIdentity, endpoint: F.peerKey, revoked: true)]
        case .selfDevice: peers = [F.record(F.identity(device: "self", team: "B"), endpoint: F.peerKey)]
        case .missingRule: rules = []
        case .otherRequester: requester = F.record(F.identity(device: "self", team: "Z"), endpoint: F.selfKey).descriptor
        case .expiredLease: expiresAt = 1500
        case .sameTeam: peers = [F.record(F.identity(device: "peer", team: "A"), endpoint: F.peerKey)]
        case .duplicateEndpoint:
            peers = [F.record(F.peerIdentity, endpoint: F.peerKey),
                     F.record(F.identity(device: "peer2", team: "C"), endpoint: F.peerKey)]
        }
        admission.apply(account: F.account(inbound: peers.map { F.inbound($0, expiresAt: expiresAt) },
            rules: rules, requester: requester), hostRecord: host)
        #expect(admission.authorizedPeer(endpointID: F.peerKey) == nil)
    }

    @Test("A lease ends at the earlier of the peer and directory expiry, on the monotonic clock")
    func expiry() throws {
        let clock = TestClock()
        let admission = try authority(clock: clock)
        let peer = F.record(F.peerIdentity, endpoint: F.peerKey)
        admission.apply(account: F.account(inbound: [F.inbound(peer, expiresAt: 1600)], expiresAt: 2000),
            hostRecord: F.hostRecord())
        #expect(admission.nextExpiration == clock.start.advanced(by: .seconds(100)))
        clock.advance(99)
        #expect(admission.authorizedPeer(endpointID: F.peerKey) != nil)
        clock.advance(2)
        #expect(admission.authorizedPeer(endpointID: F.peerKey) == nil)
        #expect(throws: IrxAdmissionDenied(code: .grantExpired)) { try admission.judgment()(nil, F.peerKey) }
        #expect(admission.nextExpiration == nil)
    }

    @Test("A newer directory without the peer revokes it; an older one cannot reinstate it")
    func revocation() throws {
        let admission = try authority()
        let peer = F.record(F.peerIdentity, endpoint: F.peerKey)
        admission.apply(account: F.account(inbound: [F.inbound(peer)], revision: 2), hostRecord: F.hostRecord())
        let admitted = try #require(admission.authorizedPeer(endpointID: F.peerKey))
        let recheck = admission.recheck(admitted)
        #expect(recheck(F.peerKey))
        admission.apply(account: F.account(inbound: [], revision: 3), hostRecord: F.hostRecord())
        #expect(!recheck(F.peerKey))
        admission.apply(account: F.account(inbound: [F.inbound(peer)], revision: 2), hostRecord: F.hostRecord())
        #expect(admission.authorizedPeer(endpointID: F.peerKey) == nil)
        // Losing the account directory (unsupported service, flag off) clears it too.
        admission.apply(account: F.account(inbound: [F.inbound(peer)], revision: 4), hostRecord: F.hostRecord())
        #expect(admission.authorizedPeer(endpointID: F.peerKey) != nil)
        admission.apply(account: nil, hostRecord: F.hostRecord())
        #expect(admission.authorizedPeer(endpointID: F.peerKey) == nil)
    }

    @Test("Invalidation is permanent")
    func invalidation() throws {
        let admission = try authority()
        let peer = F.record(F.peerIdentity, endpoint: F.peerKey)
        admission.apply(account: F.account(inbound: [F.inbound(peer)]), hostRecord: F.hostRecord())
        admission.invalidate()
        #expect(throws: IrxAdmissionDenied(code: .revoked)) { try admission.judgment()(nil, F.peerKey) }
        admission.apply(account: F.account(inbound: [F.inbound(peer)], revision: 9), hostRecord: F.hostRecord())
        #expect(admission.authorizedPeer(endpointID: F.peerKey) == nil)
    }
}

@Suite("Devices: team then account admission")
struct AccountMacAdmissionPolicyTests {
    fileprivate typealias F = AccountFixture

    /// A team authority whose directory knows `phone` (iOS) and, optionally, the peer Mac key.
    private func team(clock: TestClock = TestClock(), phoneRevoked: Bool = false,
                      peerRecord: V2DeviceRecord? = nil, peerExpiresAt: Int = 2000) throws -> V2InboundAdmissionAuthority {
        let authority = try V2InboundAdmissionAuthority(host: F.hostRecord().descriptor,
            wallNow: { F.now }, monotonicNow: { clock.now })
        let phone = F.record(F.identity(device: "phone", team: "A"), endpoint: F.phoneKey, platform: .ios,
            capabilities: ["irx-v2"], revoked: phoneRevoked)
        var inbound = [F.inbound(phone)]
        if let peerRecord { inbound.append(F.inbound(peerRecord, expiresAt: peerExpiresAt)) }
        var host = F.hostRecord()
        host = V2DeviceRecord(descriptor: V2DeviceDescriptor(endpointID: host.descriptor.endpointID,
            identity: host.descriptor.identity, identityGeneration: 1,
            metadata: V2DeviceMetadata(appVersion: "1", capabilities: host.descriptor.metadata.capabilities,
                displayName: "self", pairingEnabled: true, platform: .mac, relayURLs: [])),
            deviceRecordID: host.deviceRecordID, revision: 1, revoked: false)
        authority.restore(F.cache(host: host, teamInbound: inbound))
        return authority
    }

    private func account(clock: TestClock = TestClock(), peerKey: String = F.peerKey,
                         extra: [V2InboundPeerPermission] = []) throws -> V2AccountMacAdmissionAuthority {
        let authority = try V2AccountMacAdmissionAuthority(host: F.hostRecord().descriptor,
            wallNow: { F.now }, monotonicNow: { clock.now })
        authority.apply(account: F.account(inbound: [F.inbound(F.record(F.peerIdentity, endpoint: peerKey))] + extra),
            hostRecord: F.hostRecord())
        return authority
    }

    @Test("Only the team's unknown-endpoint answer falls through, and only while enabled")
    func fallbackRule() {
        #expect(AccountMacAdmissionPolicy.allowsFallback(after: IrxAdmissionDenied(code: .invalidGrant), enabled: true))
        #expect(!AccountMacAdmissionPolicy.allowsFallback(after: IrxAdmissionDenied(code: .invalidGrant), enabled: false))
        #expect(!AccountMacAdmissionPolicy.allowsFallback(after: IrxAdmissionDenied(code: .revoked), enabled: true))
        #expect(!AccountMacAdmissionPolicy.allowsFallback(after: IrxAdmissionDenied(code: .grantExpired), enabled: true))
        #expect(!AccountMacAdmissionPolicy.allowsFallback(after: IrxAdmissionDenied(code: .identityMismatch), enabled: true))
    }

    @Test("A team revocation is final even when the account authority would admit the key")
    func teamRevocationDoesNotFallThrough() throws {
        let revokedPeer = F.record(F.identity(device: "peer", team: "A"), endpoint: F.peerKey, revoked: true)
        let team = try team(peerRecord: revokedPeer)
        let account = try account()
        #expect(account.authorizedPeer(endpointID: F.peerKey) != nil)
        let judgment = AccountMacAdmissionPolicy.fallbackJudgment(team: team.judgment(),
            account: account.judgment(), enabled: { true })
        #expect(throws: IrxAdmissionDenied(code: .revoked)) { try judgment(nil, F.peerKey) }
    }

    @Test("A team expiry is final even when the account authority would admit the key")
    func teamExpiryDoesNotFallThrough() throws {
        let clock = TestClock()
        let teamPeer = F.record(F.identity(device: "peer", team: "A"), endpoint: F.peerKey)
        let team = try team(clock: clock, peerRecord: teamPeer, peerExpiresAt: 1510)
        let account = try account(clock: clock)
        clock.advance(20)
        #expect(account.authorizedPeer(endpointID: F.peerKey) != nil)
        let judgment = AccountMacAdmissionPolicy.fallbackJudgment(team: team.judgment(),
            account: account.judgment(), enabled: { true })
        #expect(throws: IrxAdmissionDenied(code: .grantExpired)) { try judgment(nil, F.peerKey) }
    }

    @Test("An endpoint unknown to the team is admitted by the account authority only while enabled")
    func unknownEndpointFallsThrough() throws {
        let team = try team()
        let account = try account()
        let enabled = LockedBox(true)
        let judgment = AccountMacAdmissionPolicy.fallbackJudgment(team: team.judgment(),
            account: account.judgment(), enabled: { enabled.value })
        #expect(try judgment(nil, F.peerKey).endpointIDHex == F.peerKey)
        enabled.value = false
        #expect(throws: IrxAdmissionDenied(code: .invalidGrant)) { try judgment(nil, F.peerKey) }
    }

    @Test("Phone admission and revocation are identical with the account authority present or absent",
          arguments: [false, true])
    func phoneAdmissionUnchanged(phoneRevoked: Bool) throws {
        let team = try team(phoneRevoked: phoneRevoked)
        // An account directory that (wrongly) lists the phone key as an iOS row and a Mac row with no Mac opt-in.
        let account = try account(extra: [
            F.inbound(F.record(F.identity(device: "phone", team: "B"), endpoint: F.phoneKey, platform: .ios,
                capabilities: ["cmux.mac-devices.v1"])),
        ])
        #expect(account.authorizedPeer(endpointID: F.phoneKey) == nil)
        func outcome(_ judgment: IrxGrantJudgment, _ endpoint: String) -> Result<IrxAdmittedPeerInfo, IrxAdmissionDenied> {
            do { return .success(try judgment(nil, endpoint)) }
            catch let denied as IrxAdmissionDenied { return .failure(denied) }
            catch { return .failure(IrxAdmissionDenied(code: .invalidGrant)) }
        }
        let teamOnly = team.judgment()
        let withAccount = AccountMacAdmissionPolicy.fallbackJudgment(team: team.judgment(),
            account: account.judgment(), enabled: { true })
        let withoutAccount = AccountMacAdmissionPolicy.fallbackJudgment(team: team.judgment(),
            account: nil, enabled: { true })
        for endpoint in [F.phoneKey, F.staleKey] {
            #expect(outcome(withAccount, endpoint) == outcome(teamOnly, endpoint))
            #expect(outcome(withoutAccount, endpoint) == outcome(teamOnly, endpoint))
        }
        if phoneRevoked {
            #expect(outcome(withAccount, F.phoneKey) == .failure(IrxAdmissionDenied(code: .revoked)))
        } else {
            #expect(try withAccount(nil, F.phoneKey).endpointIDHex == F.phoneKey)
        }
        // Session enforcement keeps the existing rules for every session the
        // account authority did not admit, phones included.
        #expect(AccountMacAdmissionPolicy.sessionCloses(endpoint: F.phoneKey, accountAdmitted: false,
            account: account, allowsMacAccess: false) == nil)
        #expect(AccountMacAdmissionPolicy.sessionCloses(endpoint: F.phoneKey, accountAdmitted: false,
            account: nil, allowsMacAccess: false) == nil)
    }

    @Test("Account-admitted Mac sessions close when incoming Mac access turns off")
    func incomingAccessClosesAccountSessions() throws {
        let account = try account()
        #expect(AccountMacAdmissionPolicy.sessionCloses(endpoint: F.peerKey, accountAdmitted: true,
            account: account, allowsMacAccess: false) == true)
        #expect(AccountMacAdmissionPolicy.sessionCloses(endpoint: F.peerKey, accountAdmitted: true,
            account: account, allowsMacAccess: true) == false)
        // The route disabled (flag off): account-admitted sessions close.
        #expect(AccountMacAdmissionPolicy.sessionCloses(endpoint: F.peerKey, accountAdmitted: true,
            account: nil, allowsMacAccess: true) == true)
        #expect(!AccountMacAdmissionPolicy.sessionStillAuthorized(allowsIncomingAccess: false, enabled: true) { true })
        #expect(!AccountMacAdmissionPolicy.sessionStillAuthorized(allowsIncomingAccess: true, enabled: false) { true })
        #expect(!AccountMacAdmissionPolicy.sessionStillAuthorized(allowsIncomingAccess: true, enabled: true) { false })
        #expect(AccountMacAdmissionPolicy.sessionStillAuthorized(allowsIncomingAccess: true, enabled: true) { true })
    }

    @Test("A lapsed account grant is unauthorized and its session closes under the existing rule")
    func lapsedGrantCloses() throws {
        let clock = TestClock()
        let team = try team(clock: clock)
        let account = try V2AccountMacAdmissionAuthority(host: F.hostRecord().descriptor,
            wallNow: { F.now }, monotonicNow: { clock.now })
        // The service caps an inbound account grant at five minutes.
        account.apply(account: F.account(inbound: [F.inbound(F.record(F.peerIdentity, endpoint: F.peerKey),
            expiresAt: 1800)]), hostRecord: F.hostRecord())
        let admitted = try #require(account.authorizedPeer(endpointID: F.peerKey))
        let recheck = account.recheck(admitted)
        #expect(account.nextExpiration == clock.start.advanced(by: .seconds(300)))
        #expect(AccountMacAdmissionPolicy.sessionCloses(endpoint: F.peerKey, accountAdmitted: true,
            account: account, allowsMacAccess: true) == false)
        clock.advance(300)
        #expect(!recheck(F.peerKey))
        #expect(throws: IrxAdmissionDenied(code: .grantExpired)) { try account.judgment()(nil, F.peerKey) }
        #expect(AccountMacAdmissionPolicy.sessionCloses(endpoint: F.peerKey, accountAdmitted: true,
            account: account, allowsMacAccess: true) == true)
        #expect(team.authorizedPeer(endpointID: F.peerKey) == nil)
    }

    @Test("A team-admitted session keeps the exact team rule even when the account authority knows its key")
    func teamSessionsKeepTeamRule() throws {
        let clock = TestClock()
        let teamPeer = F.record(F.identity(device: "peer", team: "A"), endpoint: F.peerKey)
        let team = try team(clock: clock, peerRecord: teamPeer, peerExpiresAt: 1510)
        let account = try account(clock: clock)
        #expect(team.authorizedPeer(endpointID: F.peerKey) != nil)
        clock.advance(20)
        // The team permission lapsed; the account entry must not keep the team session.
        #expect(team.authorizedPeer(endpointID: F.peerKey) == nil)
        #expect(account.authorizedPeer(endpointID: F.peerKey) != nil)
        for allowsMacAccess in [false, true] {
            #expect(AccountMacAdmissionPolicy.sessionCloses(endpoint: F.peerKey, accountAdmitted: false,
                account: account, allowsMacAccess: allowsMacAccess) == nil)
        }
        let sessions = AccountAdmittedSessions()
        #expect(!sessions.contains(F.peerKey))
        sessions.insert(endpoint: F.peerKey, session: "s1")
        sessions.insert(endpoint: F.peerKey, session: "s2")
        sessions.remove(endpoint: F.peerKey, session: "s1")
        #expect(sessions.contains(F.peerKey))
        sessions.remove(endpoint: F.peerKey, session: "s2")
        #expect(!sessions.contains(F.peerKey))
    }

    @Test("The account directory runs only while the flag is on, observed on, and no withdrawal is in flight")
    func directoryActiveGate() {
        #expect(AccountMacAdmissionPolicy.directoryActive(flag: true, observed: true, withdrawalsInFlight: 0))
        #expect(!AccountMacAdmissionPolicy.directoryActive(flag: false, observed: true, withdrawalsInFlight: 0))
        #expect(!AccountMacAdmissionPolicy.directoryActive(flag: true, observed: false, withdrawalsInFlight: 0))
        // An off-on flip while the off withdrawal is still running cannot publish yet.
        #expect(!AccountMacAdmissionPolicy.directoryActive(flag: true, observed: true, withdrawalsInFlight: 1))
    }

    @Test("Account credentials come only from an unrevoked Mac record with a live ticket and a Mac capability")
    func credentials() {
        #expect(AccountMacAdmissionPolicy.credentials(F.cache(), enabled: true, now: F.now) != nil)
        #expect(AccountMacAdmissionPolicy.credentials(F.cache(), enabled: false, now: F.now) == nil)
        #expect(AccountMacAdmissionPolicy.credentials(F.cache(revoked: true), enabled: true, now: F.now) == nil)
        #expect(AccountMacAdmissionPolicy.credentials(F.cache(host: F.hostRecord(revoked: true)), enabled: true, now: F.now) == nil)
        #expect(AccountMacAdmissionPolicy.credentials(F.cache(host: F.hostRecord(capabilities: ["irx-v2"])),
            enabled: true, now: F.now) == nil)
        #expect(AccountMacAdmissionPolicy.credentials(F.cache(), enabled: true,
            now: Date(timeIntervalSince1970: 2000)) == nil)
    }
}

@Suite("Devices: account directory merge and dial source")
struct AccountMacDiscoveryTests {
    fileprivate typealias F = AccountFixture

    /// Team A still lists `peer` under the key it used when it selected team A.
    private var staleTeamPeer: V2DeviceRecord {
        F.record(F.identity(device: "peer", team: "A"), endpoint: F.staleKey)
    }

    @Test("A Mac that switched teams with pairing on shows and dials its new cross-team endpoint")
    func switchedMacShowsAndDialsAccountEndpoint() throws {
        // Pairing on: the old team record keeps cmux.mac-host.v1, so team A
        // still lists peer validly under the key it used while in team A.
        let cache = F.cache(teamDevices: [staleTeamPeer])
        #expect(DeviceIrxClient.displayBindings(cache: cache, now: F.now).map(\.bindingID) == ["A-peer"])
        let merged = DeviceIrxClient.displayBindings(cache: cache, account: F.account(), now: F.now)
        #expect(merged.count == 1)
        let row = try #require(merged.first)
        #expect(row.endpointID.endpointID == F.peerKey)
        #expect(row.bindingID == "B-peer")
        #expect(row.controlPlaneSupportsMacPeers)
        // The dial resolves the shown endpoint on the account directory...
        let shown = IrxMacPeerAuthorization(deviceID: row.deviceID, tag: row.tag, endpointID: row.endpointID.endpointID)
        let target = try DeviceIrxClient.resolveTarget(intent: shown, source: nil, cache: cache,
            account: F.account(), localIdentity: F.selfIdentity, now: F.now)
        #expect(target.source == .account)
        #expect(target.record.deviceRecordID == "B-peer")
        // ...and never falls back to the team record's old key for that Mac.
        let oldKey = IrxMacPeerAuthorization(deviceID: "peer", tag: "default", endpointID: F.staleKey)
        #expect(throws: IrxMacPeerAuthorization.Failure.unavailable) {
            try DeviceIrxClient.resolveTarget(intent: oldKey, source: nil, cache: cache,
                account: F.account(), localIdentity: F.selfIdentity, now: F.now)
        }
    }

    @Test("Same-team Macs stay exactly on the team directory, whatever the account lists")
    func sameTeamStaysOnTeam() throws {
        let cache = F.cache(teamDevices: [staleTeamPeer])
        // The account row for this Mac is from this Mac's own team: never used.
        let sameTeam = F.account(macs: [F.record(F.identity(device: "peer", team: "A"), endpoint: F.peerKey)])
        let merged = DeviceIrxClient.displayBindings(cache: cache, account: sameTeam, now: F.now)
        #expect(merged.map(\.bindingID) == DeviceIrxClient.displayBindings(cache: cache, now: F.now).map(\.bindingID))
        #expect(merged.map(\.endpointID) == DeviceIrxClient.displayBindings(cache: cache, now: F.now).map(\.endpointID))
        let intent = IrxMacPeerAuthorization(deviceID: "peer", tag: "default", endpointID: F.staleKey)
        let target = try DeviceIrxClient.resolveTarget(intent: intent, source: nil, cache: cache,
            account: sameTeam, localIdentity: F.selfIdentity, now: F.now)
        #expect(target.source == .team)
        #expect(throws: IrxMacPeerAuthorization.Failure.unavailable) {
            try DeviceIrxClient.resolveTarget(intent: IrxMacPeerAuthorization(deviceID: "peer", tag: "default",
                endpointID: F.peerKey), source: nil, cache: cache, account: sameTeam,
                localIdentity: F.selfIdentity, now: F.now)
        }
    }

    @Test("Ambiguous account rows for one Mac are refused for display and for an explicit dial")
    func ambiguousAccountRowsRefused() {
        let twoRows = F.account(macs: [F.record(F.peerIdentity, endpoint: F.peerKey),
            F.record(F.identity(device: "peer", team: "C"), endpoint: F.phoneKey)])
        #expect(DeviceIrxClient.displayBindings(cache: F.cache(), account: twoRows, now: F.now).isEmpty)
        for endpoint in [F.peerKey, F.phoneKey] {
            let intent = IrxMacPeerAuthorization(deviceID: "peer", tag: "default", endpointID: endpoint)
            #expect(throws: IrxMacPeerAuthorization.Failure.identityMismatch) {
                try DeviceIrxClient.resolveTarget(intent: intent, source: .account, cache: F.cache(),
                    account: twoRows, localIdentity: F.selfIdentity, now: F.now)
            }
            #expect(throws: IrxMacPeerAuthorization.Failure.unavailable) {
                try DeviceIrxClient.resolveTarget(intent: intent, source: nil, cache: F.cache(),
                    account: twoRows, localIdentity: F.selfIdentity, now: F.now)
            }
        }
    }

    @Test("Without a usable account directory, discovery is exactly the team list", arguments: [0, 1, 2])
    func teamOnlyWithoutAccount(variant: Int) {
        let cache = F.cache(teamDevices: [staleTeamPeer])
        let account: AccountMacDirectorySnapshot? = switch variant {
        case 0: nil
        case 1: F.account(expiresAt: 1400)
        default: F.account(rules: [])
        }
        let merged = DeviceIrxClient.displayBindings(cache: cache, account: account, now: F.now)
        let team = DeviceIrxClient.displayBindings(cache: cache, now: F.now)
        #expect(merged.map(\.bindingID) == team.map(\.bindingID))
        #expect(merged.map(\.endpointID) == team.map(\.endpointID))
    }

    @Test("Each dial resolves on one source and every recheck stays on it")
    func recheckUsesSameSource() throws {
        let cache = F.cache(teamDevices: [staleTeamPeer])
        let account = F.account()
        let accountIntent = IrxMacPeerAuthorization(deviceID: "peer", tag: "default", endpointID: F.peerKey)
        let selected = try DeviceIrxClient.resolveTarget(intent: accountIntent, source: nil, cache: cache,
            account: account, localIdentity: F.selfIdentity, now: F.now)
        #expect(selected.source == .account)
        // Losing the account directory fails the recheck; the team never vouches for an account target.
        #expect(throws: IrxMacPeerAuthorization.Failure.staleDirectory) {
            try DeviceIrxClient.resolveTarget(intent: accountIntent, source: .account, cache: cache,
                account: nil, localIdentity: F.selfIdentity, now: F.now)
        }
        #expect(throws: IrxMacPeerAuthorization.Failure.unavailable) {
            try DeviceIrxClient.resolveTarget(intent: accountIntent, source: .team, cache: cache,
                account: account, localIdentity: F.selfIdentity, now: F.now)
        }
        // A team-selected target is never confirmed by an account row, and the
        // team recheck ignores the account directory entirely.
        let teamIntent = IrxMacPeerAuthorization(deviceID: "peer", tag: "default", endpointID: F.staleKey)
        let teamSelected = try DeviceIrxClient.resolveTarget(intent: teamIntent, source: nil, cache: cache,
            account: nil, localIdentity: F.selfIdentity, now: F.now)
        #expect(teamSelected.source == .team)
        let recheck = try DeviceIrxClient.resolveTarget(intent: teamIntent, source: .team, cache: cache,
            account: account, localIdentity: F.selfIdentity, now: F.now)
        #expect(recheck.source == .team)
        #expect(throws: IrxMacPeerAuthorization.Failure.unavailable) {
            try DeviceIrxClient.resolveTarget(intent: teamIntent, source: .account, cache: cache,
                account: account, localIdentity: F.selfIdentity, now: F.now)
        }
    }

    @Test("A stale team directory is final on every path, cross-team included; a revoked local device refuses both")
    func teamFailureIsFinal() {
        var stale = F.cache(teamDevices: [staleTeamPeer])
        stale.directory = V2Directory(devices: [staleTeamPeer], inboundPeers: [], issuedAt: 1000,
            permissionExpiresAt: 1400, relayURLs: [], revision: 1, teamID: "A")
        let teamIntent = IrxMacPeerAuthorization(deviceID: "peer", tag: "default", endpointID: F.staleKey)
        let sameTeam = F.account(macs: [F.record(F.identity(device: "peer", team: "A"), endpoint: F.peerKey)])
        #expect(throws: IrxMacPeerAuthorization.Failure.staleDirectory) {
            try DeviceIrxClient.resolveTarget(intent: teamIntent, source: nil, cache: stale,
                account: sameTeam, localIdentity: F.selfIdentity, now: F.now)
        }
        let accountIntent = IrxMacPeerAuthorization(deviceID: "peer", tag: "default", endpointID: F.peerKey)
        // A fresh, qualifying cross-team account row does not stand in for a
        // stale team directory: discovery and every dial path stay stale.
        for source in [nil, DeviceDirectorySource.account] {
            #expect(throws: IrxMacPeerAuthorization.Failure.staleDirectory) {
                try DeviceIrxClient.resolveTarget(intent: accountIntent, source: source, cache: stale,
                    account: F.account(), localIdentity: F.selfIdentity, now: F.now)
            }
        }
        #expect(DeviceIrxClient.displayBindings(cache: stale, account: F.account(), now: F.now).isEmpty)
        #expect(throws: IrxMacPeerAuthorization.Failure.revoked) {
            try DeviceIrxClient.resolveTarget(intent: accountIntent, source: nil, cache: F.cache(revoked: true),
                account: F.account(), localIdentity: F.selfIdentity, now: F.now)
        }
    }

    @Test("Ambiguous account rows never replace the team row; a cross-team row at the same key takes the account source")
    func ambiguousAccountRowsKeepTeam() throws {
        let cache = F.cache(teamDevices: [staleTeamPeer])
        let twoRows = F.account(macs: [F.record(F.peerIdentity, endpoint: F.peerKey),
            F.record(F.identity(device: "peer", team: "C"), endpoint: F.phoneKey)])
        let merged = DeviceIrxClient.displayBindings(cache: cache, account: twoRows, now: F.now)
        #expect(merged.map(\.bindingID) == ["A-peer"])
        let sameEndpoint = F.account(macs: [F.record(F.peerIdentity, endpoint: F.staleKey)])
        let replaced = DeviceIrxClient.displayBindings(cache: cache, account: sameEndpoint, now: F.now)
        #expect(replaced.map(\.bindingID) == ["B-peer"])
    }

    @Test("An older account directory never replaces a newer one in the outgoing client")
    func enforceAccountIsMonotonic() async {
        let client = DeviceIrxClient(context: { throw DeviceLinkError.notConnected },
            journal: IrxJournal(subsystem: "dev.cmux.tests", category: "account-monotonic"))
        await client.enforce(F.cache())
        var iterator = await client.directoryChanges().makeAsyncIterator()
        _ = await iterator.next()
        await client.enforceAccount(F.account(revision: 5))
        #expect(await iterator.next() != nil)
        await client.enforceAccount(F.account(macs: [], revision: 4))
        await client.stop()
        var updates = 0
        while await iterator.next() != nil { updates += 1 }
        #expect(updates == 0)
    }

    @Test("An account directory change refreshes My Devices once; a repeat does not")
    func accountChangesRefreshDiscovery() async {
        let client = DeviceIrxClient(context: { throw DeviceLinkError.notConnected },
            journal: IrxJournal(subsystem: "dev.cmux.tests", category: "account-discovery"))
        await client.enforce(F.cache(teamDevices: [staleTeamPeer]))
        var iterator = await client.directoryChanges().makeAsyncIterator()
        _ = await iterator.next()
        await client.enforceAccount(F.account())
        #expect(await iterator.next() != nil)
        await client.enforceAccount(F.account())
        await client.stop()
        var updates = 0
        while await iterator.next() != nil { updates += 1 }
        #expect(updates == 0)
    }

    @Test("A stamp advances on either directory's revision")
    func stampAdvances() {
        let base = DeviceDirectoryStamp(revision: 3, issuedAt: 1, accountRevision: 5)
        #expect(DeviceDirectoryStamp(revision: 4, issuedAt: 1, accountRevision: 5).advanced(since: base))
        #expect(DeviceDirectoryStamp(revision: 3, issuedAt: 2, accountRevision: 6).advanced(since: base))
        #expect(!DeviceDirectoryStamp(revision: 3, issuedAt: 2, accountRevision: 5).advanced(since: base))
        #expect(!DeviceDirectoryStamp(revision: 3, issuedAt: 2).advanced(since: base))
        #expect(DeviceDirectoryStamp(revision: 3, issuedAt: 2, accountRevision: 0)
            .advanced(since: DeviceDirectoryStamp(revision: 3, issuedAt: 1)))
    }
}
