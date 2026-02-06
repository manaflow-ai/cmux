#!/usr/bin/env swift
import CryptoKit
import Foundation

// Derives the Ed25519 public key from a Sparkle private key (base64-encoded).
// Supports both new format (32-byte seed) and old format (96-byte key+pub).

guard CommandLine.arguments.count > 1 else {
    fputs("Usage: derive_sparkle_public_key.swift <base64-private-key>\n", stderr)
    exit(1)
}

// Pad base64 string if needed (Sparkle keys may be stored without padding)
var b64 = CommandLine.arguments[1]
while b64.count % 4 != 0 {
    b64 += "="
}
guard let data = Data(base64Encoded: b64) else {
    fputs("Error: invalid base64 input\n", stderr)
    exit(1)
}

if data.count == 32 {
    // New format: 32-byte Ed25519 seed
    do {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        print(privateKey.publicKey.rawRepresentation.base64EncodedString())
    } catch {
        fputs("Error deriving key: \(error)\n", stderr)
        exit(1)
    }
} else if data.count == 96 {
    // Old format: 64-byte private key + 32-byte public key
    let pubKeyData = data[64...]
    print(pubKeyData.base64EncodedString())
} else {
    fputs("Error: unexpected key length \(data.count) (expected 32 or 96)\n", stderr)
    exit(1)
}
