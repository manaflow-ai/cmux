// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import Network

public struct IPAddressRange {
    public let address: IPAddress
    public let networkPrefixLength: UInt8

    init(address: IPAddress, networkPrefixLength: UInt8) {
        self.address = address
        self.networkPrefixLength = networkPrefixLength
    }
}

extension IPAddressRange: Equatable {
    public static func == (lhs: IPAddressRange, rhs: IPAddressRange) -> Bool {
        return lhs.address.rawValue == rhs.address.rawValue && lhs.networkPrefixLength == rhs.networkPrefixLength
    }
}

extension IPAddressRange: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(address.rawValue)
        hasher.combine(networkPrefixLength)
    }
}

extension IPAddressRange {
    public var stringRepresentation: String {
        return "\(address)/\(networkPrefixLength)"
    }

    public init?(from string: String) {
        guard let parsed = IPAddressRange.parseAddressString(string) else { return nil }
        address = parsed.0
        networkPrefixLength = parsed.1
    }

    private static func parseAddressString(_ string: String) -> (IPAddress, UInt8)? {
        let endOfIPAddress = string.lastIndex(of: "/") ?? string.endIndex
        let addressString = String(string[string.startIndex ..< endOfIPAddress])
        let address: IPAddress
        if let addr = IPv4Address(addressString) {
            address = addr
        } else if let addr = IPv6Address(addressString) {
            address = addr
        } else {
            return nil
        }

        let maxNetworkPrefixLength: UInt8 = address is IPv4Address ? 32 : 128
        var networkPrefixLength: UInt8
        if endOfIPAddress < string.endIndex { // "/" was located
            let indexOfNetworkPrefixLength = string.index(after: endOfIPAddress)
            guard indexOfNetworkPrefixLength < string.endIndex else { return nil }
            let networkPrefixLengthSubstring = string[indexOfNetworkPrefixLength ..< string.endIndex]
            guard let npl = UInt8(networkPrefixLengthSubstring) else { return nil }
            networkPrefixLength = min(npl, maxNetworkPrefixLength)
        } else {
            networkPrefixLength = maxNetworkPrefixLength
        }

        return (address, networkPrefixLength)
    }

    public func subnetMask() -> IPAddress {
        if address is IPv4Address {
            let mask = networkPrefixLength > 0 ? ~UInt32(0) << (32 - networkPrefixLength) : UInt32(0)
            let bytes = Data([
                UInt8(truncatingIfNeeded: mask >> 24),
                UInt8(truncatingIfNeeded: mask >> 16),
                UInt8(truncatingIfNeeded: mask >> 8),
                UInt8(truncatingIfNeeded: mask >> 0)
            ])
            return IPv4Address(bytes)!
        }
        if address is IPv6Address {
            var bytes = Data(repeating: 0, count: 16)
            for i in 0..<Int(networkPrefixLength/8) {
                bytes[i] = 0xff
            }
            let nibble = networkPrefixLength % 32
            if nibble != 0 {
                let mask = ~UInt32(0) << (32 - nibble)
                let i = Int(networkPrefixLength / 32 * 4)
                bytes[i + 0] = UInt8(truncatingIfNeeded: mask >> 24)
                bytes[i + 1] = UInt8(truncatingIfNeeded: mask >> 16)
                bytes[i + 2] = UInt8(truncatingIfNeeded: mask >> 8)
                bytes[i + 3] = UInt8(truncatingIfNeeded: mask >> 0)
            }
            return IPv6Address(bytes)!
        }
        fatalError()
    }

    public func maskedAddress() -> IPAddress {
        let subnet = subnetMask().rawValue
        var masked = Data(address.rawValue)
        if subnet.count != masked.count {
            fatalError()
        }
        for i in 0..<subnet.count {
            masked[i] &= subnet[i]
        }
        if subnet.count == 4 {
            return IPv4Address(masked)!
        }
        if subnet.count == 16 {
            return IPv6Address(masked)!
        }
        fatalError()
    }
}
