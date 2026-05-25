public import Foundation

/// Decodes one cmux events-stream line into a typed `CmuxEventFrame`.
///
/// The format is documented at `docs/events.md`. We tolerate forward-compat
/// fields by ignoring unknown keys, and we surface unrecognised `type` values
/// as a typed error so callers can drop or log without crashing.
public struct CmuxEventDecoder: Sendable {
    public init() {}

    public func decode(line: String) throws -> CmuxEventFrame {
        guard let data = line.data(using: .utf8) else {
            throw CmuxError.decoding("event stream line was not valid UTF-8", underlying: nil)
        }
        return try decode(data: data)
    }

    public func decode(data: Data) throws -> CmuxEventFrame {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw CmuxError.decoding("event-stream frame was not valid JSON", underlying: error)
        }
        guard let frame = object as? [String: Any] else {
            throw CmuxError.decoding("event-stream frame was not a JSON object", underlying: nil)
        }
        guard let type = frame["type"] as? String else {
            throw CmuxError.decoding("event-stream frame missing `type`", underlying: nil)
        }
        switch type {
        case "ack":
            return .ack(try Self.decodeAck(frame))
        case "event":
            return .event(try Self.decodeEvent(frame, raw: data))
        case "heartbeat":
            return .heartbeat(try Self.decodeHeartbeat(frame))
        default:
            throw CmuxError.decoding("unknown event-stream frame type: \(type)", underlying: nil)
        }
    }

    private static func decodeAck(_ frame: [String: Any]) throws -> CmuxEventFrame.Ack {
        guard let bootID = frame["boot_id"] as? String,
              let subscriptionID = frame["subscription_id"] as? String else {
            throw CmuxError.decoding("ack frame missing boot_id/subscription_id", underlying: nil)
        }
        let heartbeatSeconds = (frame["heartbeat_interval_seconds"] as? NSNumber)?.doubleValue ?? 15
        let replayCount = (frame["replay_count"] as? NSNumber)?.intValue ?? 0

        let resumeObject = frame["resume"] as? [String: Any] ?? [:]
        let resume = CmuxEventFrame.Ack.Resume(
            afterSeq: (resumeObject["after_seq"] as? NSNumber)?.intValue,
            requestedAfterSeq: (resumeObject["requested_after_seq"] as? NSNumber)?.intValue,
            oldestSeq: (resumeObject["oldest_seq"] as? NSNumber)?.intValue,
            latestSeq: (resumeObject["latest_seq"] as? NSNumber)?.intValue,
            nextSeq: (resumeObject["next_seq"] as? NSNumber)?.intValue,
            gap: (resumeObject["gap"] as? Bool) ?? false
        )

        let filters = frame["filters"] as? [String: Any] ?? [:]
        let names = (filters["names"] as? [String]) ?? []
        let categories = (filters["categories"] as? [String]) ?? []

        return CmuxEventFrame.Ack(
            bootID: bootID,
            subscriptionID: subscriptionID,
            heartbeatIntervalSeconds: heartbeatSeconds,
            replayCount: replayCount,
            resume: resume,
            filterNames: names,
            filterCategories: categories
        )
    }

    private static func decodeEvent(
        _ frame: [String: Any],
        raw: Data
    ) throws -> CmuxEventFrame.Event {
        guard
            let bootID = frame["boot_id"] as? String,
            let seq = (frame["seq"] as? NSNumber)?.intValue,
            let id = frame["id"] as? String,
            let name = frame["name"] as? String,
            let category = frame["category"] as? String,
            let source = frame["source"] as? String
        else {
            throw CmuxError.decoding("event frame missing required keys", underlying: nil)
        }
        let occurredAt = Self.parseTimestamp(frame["occurred_at"]) ?? Date()
        let payload = (frame["payload"] as? [String: Any]) ?? [:]
        let payloadData: Data
        do {
            payloadData = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            )
        } catch {
            payloadData = Data()
        }
        return CmuxEventFrame.Event(
            bootID: bootID,
            seq: seq,
            id: id,
            name: name,
            category: category,
            source: source,
            occurredAt: occurredAt,
            workspaceID: (frame["workspace_id"] as? String).map { WorkspaceID($0) },
            surfaceID: (frame["surface_id"] as? String).map { SurfaceID($0) },
            paneID: (frame["pane_id"] as? String).map { PaneID($0) },
            windowID: (frame["window_id"] as? String).map { WindowID($0) },
            payload: payloadData
        )
    }

    private static func decodeHeartbeat(_ frame: [String: Any]) throws -> CmuxEventFrame.Heartbeat {
        guard
            let bootID = frame["boot_id"] as? String,
            let subscriptionID = frame["subscription_id"] as? String,
            let latestSeq = (frame["latest_seq"] as? NSNumber)?.intValue
        else {
            throw CmuxError.decoding("heartbeat frame missing required keys", underlying: nil)
        }
        let occurredAt = Self.parseTimestamp(frame["occurred_at"]) ?? Date()
        return CmuxEventFrame.Heartbeat(
            bootID: bootID,
            subscriptionID: subscriptionID,
            latestSeq: latestSeq,
            occurredAt: occurredAt
        )
    }

    static func parseTimestamp(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: s) {
            return date
        }

        let wholeSecond = ISO8601DateFormatter()
        wholeSecond.formatOptions = [.withInternetDateTime]
        return wholeSecond.date(from: s)
    }
}
