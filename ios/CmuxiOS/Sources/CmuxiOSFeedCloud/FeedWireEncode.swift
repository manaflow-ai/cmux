import CmuxiOSFeatureKit
import Foundation

/// Encodes intents as `feed.*` op params (feed.md section 6) and op frames.
/// Pure; JSON-serializable values only.
struct FeedWireEncode {
    /// The kind's answer value (feed.md 3.4).
    static func answer(_ reply: FeedReply) -> [String: Any] {
        switch reply {
        case .permission(let allow, let scope):
            var value: [String: Any] = ["decision": allow ? "allow" : "deny"]
            if allow, let scope { value["scope"] = scope.rawValue }
            return value
        case .text(let text):
            return ["text": text.trimmingCharacters(in: .whitespacesAndNewlines)]
        case .choice(let answers):
            return ["answers": answers.mapValues { selection -> [String: Any] in
                var value: [String: Any] = ["selected": selection.selected]
                if let other = selection.other { value["other"] = other }
                return value
            }]
        case .plan(let approved, let comment):
            var value: [String: Any] = ["verdict": approved ? "approve" : "request_changes"]
            if let comment {
                let normalized = comment.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty { value["comment"] = normalized }
            }
            return value
        case .confirm(let confirmed):
            return ["confirmed": confirmed]
        }
    }

    static func params(_ intent: FeedIntent, device: String?) -> [String: Any] {
        switch intent {
        case .answer(let item, let reply):
            var params: [String: Any] = ["item": item, "answer": answer(reply)]
            if let device { params["device"] = String(device.prefix(80)) }
            return params
        case .decline(let item): return ["item": item, "reason": "declined"]
        case .read(let items): return ["items": Array(items.prefix(256))]
        case .readAll: return ["all": true]
        case .seen(let items): return ["items": Array(items.prefix(256))]
        case .archive(let items): return ["items": Array(items.prefix(256))]
        }
    }

    /// One `op` frame, origin `user` (only the user answers, feed.md 3.6).
    static func opFrame(_ intent: FeedIntent, key: IntentKey, device: String?) -> [String: Any] {
        ["t": "op", "op": intent.op, "params": params(intent, device: device),
         "idempotency_key": key.rawValue, "origin": "user"]
    }

    static func text(_ frame: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(frame),
              let data = try? JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
