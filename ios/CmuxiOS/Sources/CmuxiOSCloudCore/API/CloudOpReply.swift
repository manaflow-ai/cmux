public import CmuxMobileWire

/// The Worker's answer to one mutation. A domain refusal is HTTP 200 with
/// `ok: false`; gate refusals (403, 503) map to the same case.
public enum CloudOpReply: Hashable, Sendable {
    case committed(value: JSONValue, revision: UInt64)
    case rejected(code: String, retryable: Bool)
}
