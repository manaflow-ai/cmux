import CnxAgentChat
import CryptoKit
import Foundation

/// What the phone's approval key signs for one Allow or answer
/// (verify/phone-approvals.md; acpmux `hub/approvers.rs` checks the same
/// bytes): the domain, then each field after one NUL byte.
public struct ApprovalPayload: Sendable, Equatable {
    public static let domain = "acpmux-approver-decision-v1"
    /// How long a signature stays valid; acpmux accepts at most 300 s.
    public static let lifetime: TimeInterval = 120

    public var instance: String
    public var macDevice: String
    public var approver: String
    public var session: String
    public var permission: String
    public var option: String
    public var nonce: String
    /// Unix seconds.
    public var expiresAt: Int
    /// The answers, for a question; nil for a plain allow.
    public var answers: JSONValue?

    public init(instance: String, macDevice: String, approver: String, session: String, permission: String,
                option: String, nonce: String, expiresAt: Int, answers: JSONValue? = nil) {
        self.instance = instance
        self.macDevice = macDevice
        self.approver = approver
        self.session = session
        self.permission = permission
        self.option = option
        self.nonce = nonce
        self.expiresAt = expiresAt
        self.answers = answers
    }

    /// The signed bytes.
    public var message: Data {
        Self.joined(Self.domain, [instance, macDevice, approver, session, permission, option, nonce,
                                  String(expiresAt), Self.answersDigest(answers)])
    }

    /// `_meta.acpmux` of the `permission_respond` that carries `signature`.
    public func meta(signature: Data) -> JSONValue {
        .object(["acpmux": .object([
            "decisionNonce": .string(nonce),
            "approverDecision": .object([
                "approver": .string(approver), "expiresAt": .number(Double(expiresAt)),
                "signature": .string(Self.hex(signature)),
            ]),
        ])])
    }

    /// Lowercase hex SHA-256 of the canonical answers JSON; empty for none.
    public static func answersDigest(_ answers: JSONValue?) -> String {
        guard let answers, answers != .null else { return "" }
        var text = ""
        canonicalJSON(answers, into: &text)
        return hex(Data(SHA256.hash(data: Data(text.utf8))))
    }

    /// JSON with object keys in UTF-8 byte order, no whitespace, and only `"`,
    /// `\` and control characters escaped (acpmux `canonical_json`).
    public static func canonicalJSON(_ value: JSONValue, into out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n):
            out += n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .string(let s): canonicalString(s, into: &out)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                canonicalJSON(item, into: &out)
            }
            out += "]"
        case .object(let object):
            out += "{"
            for (index, key) in object.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }).enumerated() {
                if index > 0 { out += "," }
                canonicalString(key, into: &out)
                out += ":"
                canonicalJSON(object[key] ?? .null, into: &out)
            }
            out += "}"
        }
    }

    private static func canonicalString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{8}": out += "\\b"
            case "\u{c}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }

    static func joined(_ domain: String, _ parts: [String]) -> Data {
        var data = Data(domain.utf8)
        for part in parts {
            data.append(0)
            data.append(Data(part.utf8))
        }
        return data
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

/// What the phone's identity key signs for one link's pairing challenge
/// (cnx-hostd `pairing.rs`).
public struct LinkAuthPayload: Sendable, Equatable {
    public static let domain = "cnx-link-auth-v1"
    public var mac: String
    public var phone: String
    public var nonce: String
    public var identityKey: String
    public var approvalKey: String
    /// `pair` or `unpair`.
    public var action: String

    public init(mac: String, phone: String, nonce: String, identityKey: String, approvalKey: String, action: String) {
        self.mac = mac
        self.phone = phone
        self.nonce = nonce
        self.identityKey = identityKey
        self.approvalKey = approvalKey
        self.action = action
    }

    public var message: Data {
        ApprovalPayload.joined(Self.domain, [mac, phone, nonce, identityKey, approvalKey, action])
    }
}
