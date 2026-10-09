public import CmuxMobileWire
public import Foundation

/// `POST /v1/read` and `POST /v1/ops` for the `cloud.*` ops.
public protocol CloudAPIClient: Sendable {
    /// The read's `value`; throws `CloudAPIError.refused` with the code.
    func read(_ op: String, params: [String: JSONValue]) async throws -> JSONValue
    /// One mutation with the caller's idempotency key (origin `user`).
    /// Throws `CloudAPIError.transport` when the outcome is unknown.
    func mutate(_ op: String, params: [String: JSONValue], key: String, as principal: CloudPrincipal) async throws -> CloudOpReply

    /// Creates an authenticated Home attachment upload slot. The parameters
    /// are the body documented by `POST /v1/home/attachments/intent` and the
    /// returned value is the owner's slot/upload description.
    func attachmentIntent(params: [String: JSONValue]) async throws -> JSONValue

    /// Uploads bytes to an attachment slot (either the Worker stream URL or a
    /// presigned object URL). The URL is already authorized by the owner, so
    /// no bearer token is added. A successful Worker response is returned as a
    /// JSON value; presigned stores may return an empty body (`.null`).
    func uploadAttachmentBytes(file: URL, to uploadURL: URL, headers: [String: String],
                               progress: @escaping @Sendable (Double) -> Void) async throws -> JSONValue

    /// Commits a presigned attachment slot after its PUT has completed.
    func commitAttachment(conversation: String, slot: String) async throws -> JSONValue

    /// Mints a short-lived signed download URL for an attachment part.
    func attachmentURL(params: [String: JSONValue]) async throws -> URL

    /// Downloads a signed attachment URL into a temporary file and atomically
    /// moves it to `destination` on success. The destination is never left
    /// partial when cancellation or transport failure occurs.
    func downloadAttachment(from url: URL, to destination: URL,
                            progress: @escaping @Sendable (Double) -> Void) async throws
}

public extension CloudAPIClient {
    // Non-Home API clients can opt into the existing protocol without having
    // to implement attachment transport. CloudHomeSource maps this refusal to
    // the normal Home rejection vocabulary.
    func attachmentIntent(params: [String: JSONValue]) async throws -> JSONValue {
        _ = params
        throw CloudAPIError.refused(code: "attachments_unsupported")
    }

    func uploadAttachmentBytes(file: URL, to uploadURL: URL, headers: [String: String],
                               progress: @escaping @Sendable (Double) -> Void) async throws -> JSONValue {
        _ = file; _ = uploadURL; _ = headers; _ = progress
        throw CloudAPIError.refused(code: "attachments_unsupported")
    }

    func commitAttachment(conversation: String, slot: String) async throws -> JSONValue {
        _ = conversation; _ = slot
        throw CloudAPIError.refused(code: "attachments_unsupported")
    }

    func attachmentURL(params: [String: JSONValue]) async throws -> URL {
        _ = params
        throw CloudAPIError.refused(code: "attachments_unsupported")
    }

    func downloadAttachment(from url: URL, to destination: URL,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = url; _ = destination; _ = progress
        throw CloudAPIError.refused(code: "attachments_unsupported")
    }
}
