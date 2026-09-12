#if DEBUG
import CmuxNextTransport
import CmuxMobileRPC
import Foundation
import Testing

@testable import cmuxFeature

/// Commit-2 coverage for the redesigned dial surface: the typed denial
/// table, the typed probe-error classifier, and configure() atomicity.
@MainActor
@Suite("Next-transport dial surface")
struct NextTransportDialSurfaceTests {
    @Test("pending credential persistence preserves the sticky next route")
    func pendingPersistencePreservesRouting() async throws {
        let domain = "cmux.next-transport-routing-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: NextTransportGraduationFacade.routeTrafficDefaultsKey)
        let facade = NextTransportGraduationFacade(defaults: defaults)
        let macID = UUID().uuidString
        facade.setRouting(.next, macID: macID)
        let write = facade.credentialPersistence.enqueue(key: macID) { true }
        // No suspension: the queued MainActor completion cannot have drained.
        #expect(facade.ensureClient(macID: macID) == nil)
        #expect(facade.routing(macID: macID) == .next)
        _ = await write.value
        #expect(facade.ensureClient(macID: macID) == nil)
        #expect(facade.routing(macID: macID) == .unknown)
    }

    /// Gives each test an isolated defaults domain and Keychain namespace so
    /// identity/credential persistence from another test or app install cannot
    /// influence the assertions.
    private func makeClient() -> NextTransportDialClient {
        let id = UUID().uuidString
        let defaults = UserDefaults(suiteName: "cmux.next-transport-tests.\(id)")
            ?? UserDefaults()
        return NextTransportDialClient(
            defaults: defaults,
            keychainService: "dev.cmux.nextTransport.tests.\(id)")
    }

    // MARK: typed denial policy

    @Test(
        "typed policy invalidates on every credential denial",
        arguments: [
            "invalid-signature", "expired", "revoked",
            "key-mismatch", "device-id-mismatch", "app-mismatch", "account-mismatch",
        ])
    func typedPolicyInvalidatesCredentialDenials(raw: String) {
        guard let denial = DenialCode(rawValue: raw) else {
            Issue.record("unknown denial code \(raw)")
            return
        }
        #expect(NextTransportDenialPolicy().shouldInvalidateBootstrap(denial: denial))
    }

    @Test(
        "typed policy keeps the bootstrap for protocol denials and transport codes",
        arguments: [
            "malformed-hello", "protocol-mismatch",
            "connection-lost", "network-unavailable", "user-requested",
        ])
    func typedPolicyKeepsBootstrapOtherwise(raw: String) {
        #expect(!NextTransportDenialPolicy().shouldInvalidateBootstrap(denial: DenialCode(rawValue: raw)))
    }

    @Test("typed policy treats no-denial as keep")
    func typedPolicyNilKeepsBootstrap() {
        #expect(!NextTransportDenialPolicy().shouldInvalidateBootstrap(denial: nil))
    }

    @Test("display descriptions and bootstrap policy preserve typed close reasons")
    func displayDescriptionPreservesTypedDenial() {
        let closed = NextTransportDialState.closed(code: "expired", denial: .expired)
        #expect(closed.displayDescription == "closed (expired)")
        let lost = NextTransportDialState.closed(code: "connection-lost", denial: nil)
        #expect(lost.displayDescription == "closed (connection-lost)")
        guard case .closed(_, let credentialDenial) = closed,
              case .closed(_, let transportDenial) = lost else {
            Issue.record("expected both states to preserve their closed payload")
            return
        }
        #expect(NextTransportDenialPolicy().shouldInvalidateBootstrap(denial: credentialDenial))
        #expect(!NextTransportDenialPolicy().shouldInvalidateBootstrap(denial: transportDenial))
    }

    // MARK: probe error classifier

    @Test(
        "typed rpcError unknown-method codes are a legacy verdict",
        arguments: ["method_not_found", "unknown_method", "unsupported_method", " Method_Not_Found "])
    func probeClassifierMethodNotFoundCodes(code: String) {
        let error = MobileShellConnectionError.rpcError(code, "Unknown method")
        #expect(NextTransportProbeErrorClassifier().isMethodNotFound(error))
    }

    @Test("other rpc errors and transport failures stay inconclusive")
    func probeClassifierTransientErrors() {
        #expect(
            !NextTransportProbeErrorClassifier().isMethodNotFound(
                MobileShellConnectionError.rpcError("internal_error", "boom")))
        #expect(
            !NextTransportProbeErrorClassifier().isMethodNotFound(
                MobileShellConnectionError.requestTimedOut))
        #expect(
            !NextTransportProbeErrorClassifier().isMethodNotFound(
                MobileShellConnectionError.connectionClosed))
    }

    @Test("a code-less rpcError remains inconclusive regardless of its message")
    func probeClassifierMessageFallback() {
        let error = MobileShellConnectionError.rpcError(nil, "Method not found: mobile.next_transport.pair")
        #expect(!NextTransportProbeErrorClassifier().isMethodNotFound(error))
    }

    // MARK: configure() atomicity

    @Test("hint refresh preserves the failed-relay fallback and attempt history")
    func hintRefreshPreservesFallback() async throws {
        let client = makeClient()
        let hostKey = Data("host-key".utf8).base64EncodedString()
        let original = ticketJSON(keyB64: hostKey)
        let refreshed = ticketJSON(keyB64: hostKey, addrs: ["192.168.1.30:4433"])
        let grant = matchingGrantJSON(for: client)
        try client.configure(ticketJSON: original, grantJSON: grant)
        client.dialAttemptIndex = 3
        client.relayOnlyAttemptFailed = true
        client.hintRefresher = { (refreshed, grant, true) }
        await client.refreshHints()
        #expect(client.dialAttemptIndex == 3)
        #expect(client.relayOnlyAttemptFailed)
        #expect(client.hostAddrs == ["192.168.1.30:4433"])
        try client.configure(ticketJSON: refreshed, grantJSON: grant)
        #expect(client.dialAttemptIndex == 0)
        #expect(!client.relayOnlyAttemptFailed)
    }

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
        let client = makeClient()
        #expect(throws: NextTransportConfigureError.malformedTicket) {
            try client.configure(ticketJSON: "not json", grantJSON: "{}")
        }
        #expect(!client.isConfigured)
    }

    @Test("a good ticket with a malformed grant commits NOTHING (atomicity)")
    func malformedGrantCommitsNoTicketState() {
        let client = makeClient()
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
        let client = makeClient()
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
        let client = makeClient()
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
