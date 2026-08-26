#if DEBUG
import CmuxMobileRPC
import Foundation
import Testing

@testable import cmuxFeature

/// Commit-2 coverage for the redesigned dial surface: the typed denial
/// table, the typed probe-error classifier, and configure() atomicity.
@MainActor
@Suite("Next-transport dial surface")
struct NextTransportDialSurfaceTests {
    // MARK: typed denial policy

    @Test(
        "typed policy invalidates on every credential denial",
        arguments: [
            "invalid-signature", "expired", "revoked",
            "key-mismatch", "device-id-mismatch", "app-mismatch",
        ])
    func typedPolicyInvalidatesCredentialDenials(raw: String) {
        #expect(NextTransportDenialPolicy.shouldInvalidateBootstrap(denialRawValue: raw))
    }

    @Test(
        "typed policy keeps the bootstrap for protocol denials and transport codes",
        arguments: [
            "malformed-hello", "protocol-mismatch",
            "connection-lost", "network-unavailable", "user-requested",
        ])
    func typedPolicyKeepsBootstrapOtherwise(raw: String) {
        #expect(!NextTransportDenialPolicy.shouldInvalidateBootstrap(denialRawValue: raw))
    }

    @Test("typed policy treats no-denial as keep")
    func typedPolicyNilKeepsBootstrap() {
        #expect(!NextTransportDenialPolicy.shouldInvalidateBootstrap(denialRawValue: nil))
    }

    @Test("the display string round-trips through the string policy")
    func displayStringRoundTrips() {
        let closed = NextTransportDialState.closed(code: "expired", denial: nil)
        #expect(closed.displayDescription == "closed (expired)")
        #expect(
            NextTransportDenialPolicy.shouldInvalidateBootstrap(
                stateDescription: closed.displayDescription))
        let lost = NextTransportDialState.closed(code: "connection-lost", denial: nil)
        #expect(
            !NextTransportDenialPolicy.shouldInvalidateBootstrap(
                stateDescription: lost.displayDescription))
    }

    // MARK: probe error classifier

    @Test(
        "typed rpcError unknown-method codes are a legacy verdict",
        arguments: ["method_not_found", "unknown_method", "unsupported_method", " Method_Not_Found "])
    func probeClassifierMethodNotFoundCodes(code: String) {
        let error = MobileShellConnectionError.rpcError(code, "Unknown method")
        #expect(NextTransportProbeErrorClassifier.isMethodNotFound(error))
    }

    @Test("other rpc errors and transport failures stay inconclusive")
    func probeClassifierTransientErrors() {
        #expect(
            !NextTransportProbeErrorClassifier.isMethodNotFound(
                MobileShellConnectionError.rpcError("internal_error", "boom")))
        #expect(
            !NextTransportProbeErrorClassifier.isMethodNotFound(
                MobileShellConnectionError.requestTimedOut))
        #expect(
            !NextTransportProbeErrorClassifier.isMethodNotFound(
                MobileShellConnectionError.connectionClosed))
    }

    @Test("a code-less rpcError still matches on the message")
    func probeClassifierMessageFallback() {
        let error = MobileShellConnectionError.rpcError(nil, "Method not found: mobile.next_transport.pair")
        #expect(NextTransportProbeErrorClassifier.isMethodNotFound(error))
    }

    // MARK: configure() atomicity

    private func ticketJSON(keyB64: String, addrs: [String] = ["192.168.1.20:4433"]) -> String {
        let addrList = addrs.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"key":"\#(keyB64)","addrs":[\#(addrList)],"relay":"https://relay.example"}"#
    }

    private func grantJSON(keyB64: String, deviceID: String, app: String) -> String {
        let sig = Data("sig".utf8).base64EncodedString()
        return #"{"account":"acct-1","deviceId":"\#(deviceID)","key":"\#(keyB64)","app":"\#(app)","id":"grant-1","iat":1,"sig":"\#(sig)"}"#
    }

    /// A grant JSON minted for this exact client's identity.
    private func matchingGrantJSON(for client: NextTransportDialClient) -> String {
        grantJSON(
            keyB64: client.devicePublicKeyB64,
            deviceID: client.deviceID,
            app: "dev.cmux.next.ios")
    }

    @Test("a malformed ticket commits nothing")
    func malformedTicketCommitsNothing() {
        let client = NextTransportDialClient()
        #expect(throws: NextTransportConfigureError.malformedTicket) {
            try client.configure(ticketJSON: "not json", grantJSON: "{}")
        }
        #expect(!client.isConfigured)
    }

    @Test("a good ticket with a malformed grant commits NOTHING (atomicity)")
    func malformedGrantCommitsNoTicketState() {
        let client = NextTransportDialClient()
        #expect(throws: NextTransportConfigureError.malformedGrant) {
            try client.configure(
                ticketJSON: ticketJSON(keyB64: Data("host".utf8).base64EncodedString()),
                grantJSON: "not json")
        }
        // The old code committed hostKey/addrs/relay before parsing the
        // grant, leaving a half-applied client. Nothing may be committed.
        #expect(!client.isConfigured)
        #expect(client.configuredHostKeyB64 == nil)
    }

    @Test("a grant minted for a different device key is a typed rejection")
    func grantKeyMismatchRejected() {
        let client = NextTransportDialClient()
        let otherKey = Data(repeating: 7, count: 32).base64EncodedString()
        #expect(throws: NextTransportConfigureError.grantKeyMismatch) {
            try client.configure(
                ticketJSON: ticketJSON(keyB64: Data("host".utf8).base64EncodedString()),
                grantJSON: grantJSON(
                    keyB64: otherKey, deviceID: client.deviceID, app: "dev.cmux.next.ios"))
        }
        #expect(!client.isConfigured)
    }

    @Test("a matching pair configures, and a later bad pair keeps it")
    func validPairConfiguresAndBadReconfigureKeepsIt() throws {
        let client = NextTransportDialClient()
        let hostKey = Data("host-key".utf8).base64EncodedString()
        try client.configure(
            ticketJSON: ticketJSON(keyB64: hostKey),
            grantJSON: matchingGrantJSON(for: client))
        #expect(client.isConfigured)
        #expect(client.configuredHostKeyB64 == hostKey)

        #expect(throws: NextTransportConfigureError.malformedGrant) {
            try client.configure(
                ticketJSON: ticketJSON(keyB64: Data("other".utf8).base64EncodedString()),
                grantJSON: "not json")
        }
        // The committed pair survives a rejected reconfigure untouched.
        #expect(client.configuredHostKeyB64 == hostKey)
    }
}
#endif
