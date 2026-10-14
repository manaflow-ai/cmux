import CryptoKit
import Foundation

/// Replay protection for the backend's own Sign in with Apple path
/// (`POST /v1/auth/apple`): `hashed` goes on the `ASAuthorizationAppleIDRequest`
/// and `raw` to the backend, which checks the identity token's `nonce` claim.
/// (The primary sign-in path is Stack Auth; this one is currently unused.)
public struct AppleSignInNonce: Sendable, Hashable {
    public let raw: String
    /// Lowercase hex SHA-256 of `raw`.
    public let hashed: String

    public init() {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &rng) }
        self.init(raw: Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""))
    }

    public init(raw: String) {
        self.raw = raw
        self.hashed = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
