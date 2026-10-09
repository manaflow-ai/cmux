public import CmuxMobileWire

/// `POST /v1/read` and `POST /v1/ops` for the `cloud.*` ops.
public protocol CloudAPIClient: Sendable {
    /// The read's `value`; throws `CloudAPIError.refused` with the code.
    func read(_ op: String, params: [String: JSONValue]) async throws -> JSONValue
    /// One mutation with the caller's idempotency key (origin `user`).
    /// Throws `CloudAPIError.transport` when the outcome is unknown.
    func mutate(_ op: String, params: [String: JSONValue], key: String, as principal: CloudPrincipal) async throws -> CloudOpReply
}
