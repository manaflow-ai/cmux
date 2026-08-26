#if DEBUG
import Foundation
import Testing

@testable import cmuxFeature

/// Regression coverage for manaflow-ai/cmux graduation fallback: a phone
/// holding a stale grant (the Mac re-minted its signer, the grant expired or
/// was revoked) must drop that Mac's bootstrap and fall back to legacy. The
/// dial path reports real denials as `closed (<denial-code>)`, so a policy
/// that only recognizes the word "denied" never fires and the phone wedges
/// throwing NextTransportUnavailableError forever.
@Suite("Next-transport denial policy")
struct NextTransportDenialPolicyTests {
    /// Every state string the dial client actually publishes for the six
    /// credential denials (DenialCode raw values inside `closed (...)`).
    private static let credentialDenialStates = [
        "closed (invalid-signature)",
        "closed (expired)",
        "closed (revoked)",
        "closed (key-mismatch)",
        "closed (device-id-mismatch)",
        "closed (app-mismatch)",
    ]

    /// States that mean the transport failed or the session is simply not
    /// up: never grounds to burn the persisted ticket + grant.
    private static let transportOrBenignStates = [
        "idle",
        "connecting",
        "ready",
        "degraded",
        "closed (connection-lost)",
        "closed (network-unavailable)",
        "closed (dialTimeout)",
        "closed (user-requested)",
        "closed (superseded)",
    ]

    @Test(
        "a denial-coded close invalidates the bootstrap",
        arguments: credentialDenialStates)
    func denialCodedCloseInvalidatesBootstrap(state: String) {
        #expect(
            NextTransportDenialPolicy.shouldInvalidateBootstrap(stateDescription: state),
            "\(state) is a real admission denial; the bootstrap must be invalidated")
    }

    @Test(
        "transport-level failures keep the bootstrap",
        arguments: transportOrBenignStates)
    func transportFailureKeepsBootstrap(state: String) {
        #expect(
            !NextTransportDenialPolicy.shouldInvalidateBootstrap(stateDescription: state),
            "\(state) is not a credential denial; the bootstrap must survive")
    }
}
#endif
