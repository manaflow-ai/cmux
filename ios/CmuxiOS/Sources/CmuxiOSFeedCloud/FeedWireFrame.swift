import CmuxiOSFeatureKit
import Foundation

/// One `cmux.wire/1` frame from the feed owner (backend `OwnerFrame`).
enum FeedWireFrame: Sendable {
    case welcome(user: String)
    case snapshot(seq: UInt64, items: [FeedItem], decided: [FeedDecidedKey])
    /// `present` lists every id still held, for ops that can remove items.
    case event(seq: UInt64, items: [FeedItem], present: [String]?)
    case reject(key: String, code: String, message: String)
    case settled(key: String, sequence: UInt64, ok: Bool)
    case ignored

    static func decode(_ data: Data) -> FeedWireFrame {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let t = o["t"] as? String else { return .ignored }
        let seq = sequence(o["seq"])
        switch t {
        case "welcome":
            return ((o["principal"] as? [String: Any])?["user"] as? String).map { .welcome(user: $0) } ?? .ignored
        case "snapshot":
            let state = o["state"] as? [String: Any] ?? [:]
            let items = (state["items"] as? [String: Any] ?? [:]).values
                .compactMap { ($0 as? [String: Any]).flatMap(FeedWireDecode.item) }
            let decided = ((o["decided"] as? [[String: Any]]) ?? []).compactMap { d -> FeedDecidedKey? in
                guard let key = d["idempotency_key"] as? String else { return nil }
                return FeedDecidedKey(key: key, ok: d["ok"] as? Bool ?? false, sequence: sequence(d["sequence"]))
            }
            return .snapshot(seq: seq, items: items, decided: decided)
        case "event":
            let items = ((o["items"] as? [[String: Any]]) ?? []).compactMap(FeedWireDecode.item)
            return .event(seq: seq, items: items, present: o["present"] as? [String])
        case "reject":
            guard let key = o["idempotency_key"] as? String else { return .ignored }
            return .reject(key: key, code: o["code"] as? String ?? "", message: o["message"] as? String ?? "")
        case "request-settled":
            guard let key = o["idempotency_key"] as? String else { return .ignored }
            return .settled(key: key, sequence: sequence(o["sequence"]), ok: o["ok"] as? Bool ?? false)
        default:
            return .ignored
        }
    }

    private static func sequence(_ any: Any?) -> UInt64 {
        guard let number = any as? NSNumber, number.int64Value >= 0 else { return 0 }
        return UInt64(number.int64Value)
    }
}
