import CmuxiOSPairingCore
import CmuxMobileWire
import CmuxPairing
import CryptoKit
import Foundation

/// Signed certs and owner events shaped like the backend's `trust:` stream.
struct PairingFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let account = PairingAccount(user: "user_a1", install: "inst_p1", environment: "test")

    struct Signer: LinkKeySigning {
        let key = P256.Signing.PrivateKey()
        func sign(_ message: Data) async throws -> Data { try key.signature(for: message).rawRepresentation }
    }

    let mac = Signer()
    let phone = Signer()
    let otherMac = Signer()
    let macKey = Data(repeating: 1, count: 32)
    let otherMacKey = Data(repeating: 2, count: 32)

    func cert(_ s: Signer, user: String, install: String, key: Data) async throws -> LinkCertificate {
        try await LinkCertificateIssuer(environment: "test", user: user, install: install, signer: s).issue(purpose: .direct, key: key, now: Self.now)
    }

    func event(_ op: String, _ params: [String: JSONValue], seq: UInt64) -> EventFrame {
        EventFrame(stream: "trust:user_a1", seq: seq, tx: "tx", op: op, params: .object(params), actor: [:], origin: .script, at: 1_800_000_000_000 + Int64(seq))
    }

    func keySet(_ s: Signer, install: String, kind: String, name: String, host: String?, key: Data, seq: UInt64) async throws -> EventFrame {
        var params: [String: JSONValue] = [
            "cert": try JSONValue(encoding: try await cert(s, user: "user_a1", install: install, key: key)),
            "kind": .string(kind), "name": .string(name), "platform": .string(kind == "mac" ? "macos" : "ios"),
            "public_jwk": try JSONValue(encoding: InstallPublicKey(s.key.publicKey)),
        ]
        if let host { params["host"] = .string(host) }
        return event("trust.key.set", params, seq: seq)
    }

    func claimResult(status: PairingClaimStatus, key: Data? = nil) async throws -> PairingClaimResult {
        let cert = try await self.cert(otherMac, user: "user_b1", install: "inst_bm", key: key ?? otherMacKey)
        let value: JSONValue = .object([
            "status": .string(status.rawValue), "offer_id": .string(String(repeating: "o", count: 43)), "host": .string("host_b1"),
            "team": .string("team_b1"), "name": .string("Bea's Mac"), "owner_user": .string("user_b1"), "host_install": .string("inst_bm"),
            "host_jwk": try JSONValue(encoding: InstallPublicKey(otherMac.key.publicKey)), "host_cert": try JSONValue(encoding: cert),
        ])
        return try value.decode(as: PairingClaimResult.self)
    }

    var link: URL {
        PairingLink(kind: .pair(PairingOffer(code: String(repeating: "A", count: 26), host: "host_b1", team: "team_b1",
                                             hostKey: otherMacKey.base64URLEncodedString(), expiresAt: Self.now.addingTimeInterval(300), name: "Bea's Mac"))).url
    }
}
