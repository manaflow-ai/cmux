import CmuxIrxTransport
import CmuxMobileRPC
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Every failure a device link can see maps to one class that decides
/// recovery. The regression from https://github.com/manaflow-ai/cmux/issues/13458:
/// the other Mac refusing admission (`invalid-grant`) is that Mac's decision,
/// not a network failure, and must never be retried as one.
@Suite("Devices: link failure classification")
struct DeviceLinkFailureTests {
    private let host = "Austin\u{2019}s MacBook Pro"

    @Test("Confirmed Mac opt-out gives discoverability guidance and waits for a directory update")
    func undiscoverablePeerIsNotAnIdentityOrNetworkFailure() throws {
        let local = V2Identity(appNamespace: "cmux", buildTag: "nightly", deviceID: "viewer",
            environment: "test", projectID: "project", teamID: "team", userID: "owner")
        let remote = V2Identity(appNamespace: "cmux", buildTag: "nightly", deviceID: "host",
            environment: "test", projectID: "project", teamID: "team", userID: "owner")
        func record(_ identity: V2Identity, endpoint: String) -> V2DeviceRecord {
            V2DeviceRecord(descriptor: V2DeviceDescriptor(endpointID: endpoint, identity: identity, identityGeneration: 0,
                metadata: V2DeviceMetadata(appVersion: "1", capabilities: [], displayName: "Mac",
                    pairingEnabled: true, platform: .mac, relayURLs: [])),
                deviceRecordID: identity.deviceID, revision: 1, revoked: false)
        }
        var cache = V2CachedState(identity: local)
        cache.device = record(local, endpoint: "local-key")
        cache.directory = V2Directory(devices: [record(remote, endpoint: "remote-key")], issuedAt: 1000,
            permissionExpiresAt: 1060, relayURLs: [], revision: 1, teamID: "team")
        do {
            _ = try IrxMacPeerAuthorization(deviceID: remote.deviceID, tag: remote.buildTag, endpointID: "remote-key")
                .resolve(cache: cache, localIdentity: local, now: Date(timeIntervalSince1970: 1001))
            Issue.record("A Mac without hosting opt-in must not be authorized")
        } catch {
            let failure = DeviceLinkFailure.classify(error, hostName: host)
            #expect(failure.code == "peer-not-discoverable")
            #expect(failure.kind == .hostDenied)
            #expect(!failure.isRetryable)
            #expect(failure.message != DeviceLinkError.identityMismatch.localizedDescription)
            var policy = DeviceLinkReconnectPolicy()
            _ = policy.apply(.directory(dialable: true), now: .distantPast)
            #expect(policy.apply(.connectFailed(failure)) == .blocked(failure))
            #expect(policy.apply(.directoryRevisionAdvanced) == .connecting(attempt: 1))
        }
    }

    @Test("A host admission refusal names the Mac, keeps its code, and does not retry")
    func hostAdmissionRefusal() {
        let failure = DeviceLinkFailure.classify(IrxAdmissionDenied(code: .invalidGrant), hostName: host)
        #expect(failure.kind == .hostDenied)
        #expect(!failure.isRetryable)
        #expect(failure.code == "invalid-grant")
        #expect(failure.message.contains(host))
        #expect(!failure.message.contains("online"), "the Mac answered, so the row must not tell the person to check that it is online")
    }

    @Test("Every terminal admission code parks the link; only a missing admission reply retries",
          arguments: [
            (IrxCloseCode.grantExpired, DeviceLinkFailure.Kind.hostDenied),
            (.revoked, .hostDenied),
            (.identityMismatch, .identity),
            (.malformedHello, .unsupported),
            (.protocolMismatch, .unsupported),
            (.admissionTimeout, .transient),
            (.superseded, .transient),
          ])
    func admissionCodes(code: IrxCloseCode, kind: DeviceLinkFailure.Kind) {
        let failure = DeviceLinkFailure.classify(IrxAdmissionDenied(code: code), hostName: host)
        #expect(failure.kind == kind)
        #expect(failure.code == code.rawValue)
        #expect(failure.isRetryable == (kind == .transient))
    }

    @Test("Directory permission failures on this side are classified by what can change them")
    func peerAuthorizationFailures() {
        #expect(DeviceLinkFailure.classify(IrxMacPeerAuthorization.Failure.staleDirectory, hostName: host).kind == .transient)
        #expect(DeviceLinkFailure.classify(IrxMacPeerAuthorization.Failure.unavailable, hostName: host).kind == .transient)
        #expect(DeviceLinkFailure.classify(IrxMacPeerAuthorization.Failure.revoked, hostName: host).kind == .identity)
        #expect(DeviceLinkFailure.classify(IrxMacPeerAuthorization.Failure.identityMismatch, hostName: host).kind == .identity)
    }

    @Test("Route, identity, and transport failures keep their existing recovery")
    func existingClasses() {
        #expect(DeviceLinkFailure.classify(DeviceRouteSelector.SelectionError.needsAuthorization, hostName: host).kind == .unsupported)
        #expect(DeviceLinkFailure.classify(DeviceRouteSelector.SelectionError.noRoutes, hostName: host).isRetryable == false)
        #expect(DeviceLinkFailure.classify(DeviceLinkError.identityMismatch, hostName: host).kind == .identity)
        #expect(DeviceLinkFailure.classify(DeviceLinkError.notConnected, hostName: host).kind == .transient)
        #expect(DeviceLinkFailure.classify(MobileShellConnectionError.accountMismatch("x"), hostName: host).kind == .identity)
        #expect(DeviceLinkFailure.classify(MobileShellConnectionError.connectionClosed, hostName: host).kind == .transient)
        let unknown = DeviceLinkFailure.classify(URLError(.cannotConnectToHost), hostName: host)
        #expect(unknown.kind == .transient)
        #expect(unknown.code == "connection-failed")
        #expect(unknown.message == DeviceLinkFailure.connectionFailedMessage)
    }
}
