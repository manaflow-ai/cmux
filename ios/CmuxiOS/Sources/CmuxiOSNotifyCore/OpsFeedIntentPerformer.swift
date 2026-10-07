public import CmuxFeedPushCore
public import CmuxiOSFeatureKit
import CmuxiOSFeedCloud

/// Sends a feed intent as one `POST /v1/ops` (origin `user`, the install
/// principal). The key is the intent's, so a resend of the same banner tap
/// is a replay at the owner. A domain refusal is a refused receipt; no
/// network or no install throws (the caller says "not sent").
public struct OpsFeedIntentPerformer: FeedIntentPerforming {
    public enum Failure: Error, Hashable, Sendable {
        /// The intent's params are not JSON the op endpoint accepts.
        case unencodable
    }

    private let ops: any CloudOpsSending
    private let device: String?

    public init(ops: any CloudOpsSending, device: String?) {
        self.ops = ops
        self.device = device
    }

    /// The op request for `intent` (tests read it).
    public func op(for intent: FeedIntent, key: IntentKey) throws -> CloudOp {
        guard case .object(let params)? = JSONValue(foundation: intent.wireParams(device: device)) else {
            throw Failure.unencodable
        }
        return CloudOp(op: intent.op, params: params, idempotencyKey: key.rawValue, origin: "user")
    }

    public func perform(_ intent: FeedIntent, key: IntentKey) async throws -> IntentReceipt {
        let request = try op(for: intent, key: key)
        do {
            try await ops.send(request)
        } catch CloudOpsError.rejected(let code, retryable: false) {
            return .refused(key: key, reason: code)
        }
        // `/v1/ops` answers before the feed socket's event: the mirror catches up on its own.
        return .committed(key: key, revision: 0)
    }
}
