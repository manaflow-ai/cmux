import CryptoKit
import Foundation
import Security

private let cmxDefaultIrohALPN = "/cmux/cmx/3"
private let cmxSupportedIrohALPNs: Set<String> = [cmxDefaultIrohALPN, "/cmux/native/1"]

struct CmxPairingStart: Codable, Equatable {
    let type: String
    let pairingID: String
    let clientNonce: String

    enum CodingKeys: String, CodingKey {
        case type
        case pairingID = "pairing_id"
        case clientNonce = "client_nonce"
    }
}

struct CmxPairingChallenge: Codable, Equatable {
    let type: String
    let pairingID: String
    let serverNonce: String
    let alpn: String

    enum CodingKeys: String, CodingKey {
        case type
        case pairingID = "pairing_id"
        case serverNonce = "server_nonce"
        case alpn
    }
}

struct CmxPairingResponse: Codable, Equatable {
    let type: String
    let pairingID: String
    let proof: String

    enum CodingKeys: String, CodingKey {
        case type
        case pairingID = "pairing_id"
        case proof
    }
}

struct CmxPairingAccepted: Codable, Equatable {
    let type: String
}

enum CmxPairingAuthError: LocalizedError, Equatable {
    case pairingIDMismatch
    case unsupportedALPN(String)
    case nonceGenerationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .pairingIDMismatch:
            return String(localized: "pairing.error.id_mismatch", defaultValue: "The pairing challenge does not match this ticket.")
        case .unsupportedALPN(let alpn):
            return String(
                format: String(localized: "pairing.error.alpn", defaultValue: "Unsupported pairing protocol %@."),
                alpn
            )
        case .nonceGenerationFailed:
            return String(localized: "pairing.error.nonce", defaultValue: "Could not generate a secure pairing nonce.")
        }
    }
}

enum CmxPairingAuth {
    static func makeStart(pairingID: String) throws -> CmxPairingStart {
        try makeStart(pairingID: pairingID, clientNonce: makeNonce())
    }

    static func makeStart(pairingID: String, clientNonce: String) -> CmxPairingStart {
        CmxPairingStart(type: "pairing_start", pairingID: pairingID, clientNonce: clientNonce)
    }

    static func makeResponse(
        secret: String,
        start: CmxPairingStart,
        challenge: CmxPairingChallenge
    ) throws -> CmxPairingResponse {
        guard challenge.pairingID == start.pairingID else {
            throw CmxPairingAuthError.pairingIDMismatch
        }
        guard cmxSupportedIrohALPNs.contains(challenge.alpn) else {
            throw CmxPairingAuthError.unsupportedALPN(challenge.alpn)
        }
        return CmxPairingResponse(
            type: "pairing_response",
            pairingID: start.pairingID,
            proof: proof(
                secret: secret,
                alpn: challenge.alpn,
                pairingID: start.pairingID,
                clientNonce: start.clientNonce,
                serverNonce: challenge.serverNonce
            )
        )
    }

    static func proof(
        secret: String,
        alpn: String = cmxDefaultIrohALPN,
        pairingID: String,
        clientNonce: String,
        serverNonce: String
    ) -> String {
        let message = "\(alpn)\n\(pairingID)\n\(clientNonce)\n\(serverNonce)"
        let key = SymmetricKey(data: Data(secret.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(code).base64URLEncodedString()
    }

    static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    private static func makeNonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw CmxPairingAuthError.nonceGenerationFailed(status)
        }
        return Data(bytes).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
