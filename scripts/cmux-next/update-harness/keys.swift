#!/usr/bin/env swift
// Throwaway EdDSA (Ed25519) key for the update harness (run.py). Never a
// release or nightly key: a new key per run, written to the run's own
// directory (mode 0600) and deleted with it.
//
//   keys.swift generate <dir>   writes <dir>/private.key, prints the public key (SUPublicEDKey)
//   keys.swift sign <dir> <file>  prints the file's sparkle:edSignature
//
// The private key never travels on argv or stdout.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else { fail("usage: keys.swift generate <dir> | sign <dir> <file>") }
let keyURL = URL(fileURLWithPath: arguments[2]).appendingPathComponent("private.key")

switch arguments[1] {
case "generate":
    let key = Curve25519.Signing.PrivateKey()
    let text = key.rawRepresentation.base64EncodedString()
    guard FileManager.default.createFile(atPath: keyURL.path, contents: Data(text.utf8),
                                         attributes: [.posixPermissions: 0o600]) else { fail("cannot write \(keyURL.path)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard arguments.count == 4 else { fail("usage: keys.swift sign <dir> <file>") }
    guard let text = try? String(contentsOf: keyURL, encoding: .utf8),
          let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { fail("cannot read \(keyURL.path)") }
    guard let data = FileManager.default.contents(atPath: arguments[3]) else { fail("cannot read \(arguments[3])") }
    guard let signature = try? key.signature(for: data) else { fail("cannot sign") }
    print(signature.base64EncodedString())
default:
    fail("unknown command \(arguments[1])")
}
