import Foundation

/// Push endpoints of the cmux-next native Worker (JSON bodies with mixed
/// types, which `APIClient` does not send).
struct PushAPI: Sendable {
    var base: URL = APIClient.configuredBase
    var token: String?

    struct Failure: LocalizedError, Sendable {
        var status: Int
        var code: String
        var errorDescription: String? {
            code == "host_offline" ? String(localized: "Your Mac is offline.") : String(localized: "Couldn't reach cmux (\(status)).")
        }
    }

    func register(deviceToken: String, environment: String, bundleID: String?, pushToStartToken: String?,
                  liveActivities: Bool, notifications: Bool) async throws {
        var body: [String: Any] = [
            "apns_token": deviceToken, "environment": environment,
            "live_activities": liveActivities, "notifications": notifications,
        ]
        if let bundleID { body["bundle_id"] = bundleID }
        if let pushToStartToken { body["push_to_start_token"] = pushToStartToken }
        try await post("/v1/push/register", body)
    }

    func liveActivity(deviceToken: String, hostID: String, surface: Int, activityID: String, pushToken: String?,
                      startedAt: Double?, ended: Bool) async throws {
        var body: [String: Any] = [
            "device_token": deviceToken, "host_id": hostID, "surface": surface, "activity_id": activityID, "ended": ended,
        ]
        if let pushToken { body["push_token"] = pushToken }
        if let startedAt { body["started_at"] = startedAt * 1000 }
        try await post("/v1/push/live-activity", body)
    }

    /// A notification response: `reply` (text), `option` (key), `allow`, `deny`.
    func action(hostID: String, eventID: String, action: String, text: String? = nil, key: String? = nil) async throws {
        var body: [String: Any] = ["host_id": hostID, "event_id": eventID, "action": action]
        if let text { body["text"] = text }
        if let key { body["key"] = key }
        try await post("/v1/push/action", body)
    }

    private func post(_ path: String, _ body: [String: Any]) async throws {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let code = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }?["code"] as? String
            throw Failure(status: status, code: code ?? "http_\(status)")
        }
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
