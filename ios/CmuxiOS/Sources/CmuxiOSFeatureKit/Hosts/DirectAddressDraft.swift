import Foundation

/// The "Add direct address" form's fields (lane B4). Turns what the user
/// typed into a `HostDraft` for `HostsStore.add`, or the issues to show.
/// The carrier re-validates and classifies the address when it dials.
public struct DirectAddressDraft: Hashable, Sendable {
    /// The port hosts listen on unless told otherwise (CmuxLinkDirect
    /// `DirectEndpoint.defaultPort`).
    public static let defaultPort: UInt16 = 4180

    public var name: String
    public var address: String
    /// Empty means `defaultPort`.
    public var port: String
    /// The host key shown by the Mac (base64), or filled from pairing.
    public var hostKey: String

    public init(name: String = "", address: String = "", port: String = "", hostKey: String = "") {
        self.name = name
        self.address = address
        self.port = port
        self.hostKey = hostKey
    }

    /// Edits an existing direct record.
    public init?(record: HostRecord) {
        guard case let .direct(endpoint, key) = record.kind else { return nil }
        self.init(
            name: record.name, address: endpoint.address,
            port: endpoint.port.map(String.init) ?? "", hostKey: key.rawValue
        )
    }

    public var issues: [DirectAddressIssue] {
        var issues: [DirectAddressIssue] = []
        if let issue = Self.addressIssue(normalizedAddress) { issues.append(issue) }
        if parsedPort == nil { issues.append(.portInvalid) }
        let key = hostKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            issues.append(.hostKeyMissing)
        } else if DirectHostKey(rawValue: key) == nil {
            issues.append(.hostKeyInvalid)
        }
        return issues
    }

    public var isValid: Bool { issues.isEmpty }

    /// The draft to save, or nil while `issues` is not empty.
    public func hostDraft() -> HostDraft? {
        guard isValid, let port = parsedPort, let key = DirectHostKey(rawValue: hostKey) else { return nil }
        let address = normalizedAddress
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return HostDraft(
            name: trimmedName.isEmpty ? address : trimmedName,
            kind: .direct(endpoint: HostEndpoint(address: address, port: port), hostKey: key)
        )
    }

    var normalizedAddress: String {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        return text
    }

    var parsedPort: UInt16? {
        let text = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return Self.defaultPort }
        guard let value = UInt16(text), value > 0 else { return nil }
        return value
    }

    static func addressIssue(_ address: String) -> DirectAddressIssue? {
        guard !address.isEmpty else { return .addressMissing }
        if address.contains("://") || address.contains("/") || address.contains("@")
            || address.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) {
            return .addressInvalid
        }
        let colons = address.filter { $0 == ":" }.count
        if colons == 1 { return .addressHasPort }
        if colons > 1 {
            // IPv6: hex digits, colons, dots (mapped IPv4) and a %zone.
            let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.%")
                .union(.alphanumerics)
            return address.unicodeScalars.allSatisfy(allowed.contains) ? nil : .addressInvalid
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        guard address.unicodeScalars.allSatisfy(allowed.contains), !address.hasPrefix("."), !address.contains("..") else {
            return .addressInvalid
        }
        return nil
    }
}
