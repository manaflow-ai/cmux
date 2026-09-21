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
