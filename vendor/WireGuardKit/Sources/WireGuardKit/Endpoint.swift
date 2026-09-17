// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import Network

public struct Endpoint {
    public let host: NWEndpoint.Host
    public let port: NWEndpoint.Port

    public init(host: NWEndpoint.Host, port: NWEndpoint.Port) {
        self.host = host
        self.port = port
    }
}

extension Endpoint: Equatable {
    public static func == (lhs: Endpoint, rhs: Endpoint) -> Bool {
        return lhs.host == rhs.host && lhs.port == rhs.port
    }
}

extension Endpoint: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(host)
        hasher.combine(port)
    }
}

extension Endpoint {
    public var stringRepresentation: String {
        switch host {
        case .name(let hostname, _):
            return "\(hostname):\(port)"
        case .ipv4(let address):
            return "\(address):\(port)"
        case .ipv6(let address):
            return "[\(address)]:\(port)"
        @unknown default:
            fatalError()
        }
    }

    public init?(from string: String) {
        // Separation of host and port is based on 'parse_endpoint' function in
        // https://git.zx2c4.com/wireguard-tools/tree/src/config.c
        guard !string.isEmpty else { return nil }
        let startOfPort: String.Index
        let hostString: String
        if string.first! == "[" {
            // Look for IPv6-style endpoint, like [::1]:80
            let startOfHost = string.index(after: string.startIndex)
            guard let endOfHost = string.dropFirst().firstIndex(of: "]") else { return nil }
            let afterEndOfHost = string.index(after: endOfHost)
            if afterEndOfHost == string.endIndex { return nil }
            guard string[afterEndOfHost] == ":" else { return nil }
            startOfPort = string.index(after: afterEndOfHost)
            hostString = String(string[startOfHost ..< endOfHost])
        } else {
            // Look for an IPv4-style endpoint, like 127.0.0.1:80
            guard let endOfHost = string.firstIndex(of: ":") else { return nil }
            startOfPort = string.index(after: endOfHost)
            hostString = String(string[string.startIndex ..< endOfHost])
        }
        guard let endpointPort = NWEndpoint.Port(String(string[startOfPort ..< string.endIndex])) else { return nil }
        let invalidCharacterIndex = hostString.unicodeScalars.firstIndex { char in
            return !CharacterSet.urlHostAllowed.contains(char)
        }
        guard invalidCharacterIndex == nil else { return nil }
        host = NWEndpoint.Host(hostString)
        port = endpointPort
    }
}

extension Endpoint {
    public func hasHostAsIPAddress() -> Bool {
        switch host {
        case .name:
            return false
        case .ipv4:
            return true
        case .ipv6:
            return true
        @unknown default:
            fatalError()
        }
    }

    public func hostname() -> String? {
        switch host {
        case .name(let hostname, _):
            return hostname
        case .ipv4:
            return nil
        case .ipv6:
            return nil
        @unknown default:
            fatalError()
        }
    }
}
