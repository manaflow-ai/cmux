#if DEBUG
import CMUXMobileCore
import CmuxIrohTransport
import CmuxMobileRPC
import CmuxMobileShell
import CmuxNextTransport
import CmuxNextTransportBridge
import Foundation
import OSLog
import Security

/// Decides whether a dial client's reported session state means this Mac's
/// persisted bootstrap (ticket + grant) is no longer trustworthy. A real
/// admission denial means the credentials themselves are bad (the Mac
/// re-minted its signer, the grant expired or was revoked): the bootstrap
/// must be dropped so the legacy channel can re-credential. Extracted pure
/// so the regression suite can pin the decision table.
struct NextTransportDenialPolicy: Sendable {
    /// The denial codes that prove the CREDENTIALS are bad. The two
    /// protocol-shaped denials (`malformed-hello`, `protocol-mismatch`) are
    /// build or wire bugs, not credential staleness: re-minting the same
    /// grant would change nothing, so they never burn the bootstrap.
    let credentialDenials: Set<DenialCode>

    init(credentialDenials: Set<DenialCode> = [
        .invalidSignature, .expired, .revoked,
        .keyMismatch, .deviceIDMismatch, .appMismatch, .accountMismatch,
    ]) {
        self.credentialDenials = credentialDenials
    }

    /// Whether one typed denial proves a credential denial. Transport-level
    /// failures reach this as nil and never invalidate.
    func shouldInvalidateBootstrap(denial: DenialCode?) -> Bool {
        guard let denial else { return false }
        return credentialDenials.contains(denial)
    }

}
#endif
