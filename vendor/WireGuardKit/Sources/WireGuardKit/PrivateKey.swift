// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation

#if SWIFT_PACKAGE
import WireGuardKitC
#endif

/// The class describing a private key used by WireGuard.
public class PrivateKey: BaseKey {
    /// Derived public key
    public var publicKey: PublicKey {
        return rawValue.withUnsafeBytes { (privateKeyBufferPointer: UnsafeRawBufferPointer) -> PublicKey in
            var publicKeyData = Data(repeating: 0, count: Int(WG_KEY_LEN))
            let privateKeyBytes = privateKeyBufferPointer.baseAddress!.assumingMemoryBound(to: UInt8.self)

            publicKeyData.withUnsafeMutableBytes { (publicKeyBufferPointer: UnsafeMutableRawBufferPointer) in
                let publicKeyBytes = publicKeyBufferPointer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                curve25519_derive_public_key(publicKeyBytes, privateKeyBytes)
            }

            return PublicKey(rawValue: publicKeyData)!
        }
    }

    /// Initialize new private key
    convenience public init() {
        var privateKeyData = Data(repeating: 0, count: Int(WG_KEY_LEN))
        privateKeyData.withUnsafeMutableBytes { (rawBufferPointer: UnsafeMutableRawBufferPointer) in
            let privateKeyBytes = rawBufferPointer.baseAddress!.assumingMemoryBound(to: UInt8.self)
            curve25519_generate_private_key(privateKeyBytes)
        }
        self.init(rawValue: privateKeyData)!
    }
}

/// The class describing a public key used by WireGuard.
public class PublicKey: BaseKey {}

/// The class describing a pre-shared key used by WireGuard.
public class PreSharedKey: BaseKey {}

/// The base key implementation. Should not be used directly.
public class BaseKey: RawRepresentable, Equatable, Hashable {
    /// Raw key representation
    public let rawValue: Data

    /// Hex encoded representation
    public var hexKey: String {
        return rawValue.withUnsafeBytes { (rawBufferPointer: UnsafeRawBufferPointer) -> String in
            let inBytes = rawBufferPointer.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var outBytes = [CChar](repeating: 0, count: Int(WG_KEY_LEN_HEX))
            key_to_hex(&outBytes, inBytes)
            return String(cString: outBytes, encoding: .ascii)!
        }
    }

    /// Base64 encoded representation
    public var base64Key: String {
        return rawValue.withUnsafeBytes { (rawBufferPointer: UnsafeRawBufferPointer) -> String in
            let inBytes = rawBufferPointer.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var outBytes = [CChar](repeating: 0, count: Int(WG_KEY_LEN_BASE64))
            key_to_base64(&outBytes, inBytes)
            return String(cString: outBytes, encoding: .ascii)!
        }
    }

    /// Initialize the key with existing raw representation
    required public init?(rawValue: Data) {
        if rawValue.count == WG_KEY_LEN {
            self.rawValue = rawValue
        } else {
            return nil
        }
    }

    /// Initialize the key with hex representation
    public convenience init?(hexKey: String) {
        var bytes = Data(repeating: 0, count: Int(WG_KEY_LEN))
        let success = bytes.withUnsafeMutableBytes { (bufferPointer: UnsafeMutableRawBufferPointer) -> Bool in
            return key_from_hex(bufferPointer.baseAddress!.assumingMemoryBound(to: UInt8.self), hexKey)
        }
        if success {
            self.init(rawValue: bytes)
        } else {
            return nil
        }
    }

    /// Initialize the key with base64 representation
    public convenience init?(base64Key: String) {
        var bytes = Data(repeating: 0, count: Int(WG_KEY_LEN))
        let success = bytes.withUnsafeMutableBytes { (bufferPointer: UnsafeMutableRawBufferPointer) -> Bool in
            return key_from_base64(bufferPointer.baseAddress!.assumingMemoryBound(to: UInt8.self), base64Key)
        }
        if success {
            self.init(rawValue: bytes)
        } else {
            return nil
        }
    }

    public static func == (lhs: BaseKey, rhs: BaseKey) -> Bool {
        return lhs.rawValue.withUnsafeBytes { (lhsBytes: UnsafeRawBufferPointer) -> Bool in
            return rhs.rawValue.withUnsafeBytes { (rhsBytes: UnsafeRawBufferPointer) -> Bool in
                return key_eq(
                    lhsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    rhsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                )
            }
        }
    }
}
