import Foundation

/// Mock answers for the agent-hook delivery-target protocol.
///
/// Since #11976 every agent hook resolves where it delivers through
/// `surface.list` and `agent.resolve_delivery_target` before it publishes a
/// notification or status. A mock that answers those probes with an empty
/// `ok` result makes the CLI treat the target as failed and refuse the
/// ambient claim, so the hook exits 0 without publishing anything; that is
/// what turned every Codex Stop hook test red (run 34416451322 shard 6/6).
/// This answers the probes the way the app does for a hook that runs in the
/// given workspace and surface, and returns nil for every other request so
/// the caller's own handler stays in charge of them.
func cliMockAgentHookDeliveryTargetResponse(
    line: String,
    workspaceId: String,
    surfaceId: String
) -> String? {
    guard let data = line.data(using: .utf8),
          let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
          let id = payload["id"] as? String,
          let method = payload["method"] as? String else {
        return nil
    }
    let params = (payload["params"] as? [String: Any]) ?? [:]
    let result: [String: Any]
    switch method {
    case "surface.list":
        result = ["surfaces": [["id": surfaceId, "ref": "surface:1", "index": 1, "focused": true]]]
    case "agent.resolve_delivery_target":
        var target: [String: Any] = ["workspace_id": workspaceId, "surface_id": surfaceId]
        if params["pid"] != nil {
            target["source"] = "pid"
            target["pid_resolution"] = (params["pid_resolution"] as? String) ?? "corroborated"
        } else {
            target["source"] = "surface"
        }
        result = target
    default:
        return nil
    }
    let response: [String: Any] = ["id": id, "ok": true, "result": result]
    let encoded = try? JSONSerialization.data(withJSONObject: response, options: [])
    return String(data: encoded ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
}

/// The "accept everything" reply many hook tests use for requests they do not
/// care about: `ok` with an empty result for any v2 request, `OK` otherwise.
func cliMockAcceptAnyResponse(line: String) -> String {
    guard let data = line.data(using: .utf8),
          let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
          let id = payload["id"] as? String else {
        return "OK"
    }
    let response: [String: Any] = ["id": id, "ok": true, "result": [String: Any]()]
    let encoded = try? JSONSerialization.data(withJSONObject: response, options: [])
    return String(data: encoded ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
}
