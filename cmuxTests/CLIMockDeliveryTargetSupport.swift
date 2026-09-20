import Foundation

/// Answers the delivery-target discovery requests made by agent hooks.
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
        return nil
    default:
        return nil
    }
    let response: [String: Any] = ["id": id, "ok": true, "result": result]
    let encoded = try? JSONSerialization.data(withJSONObject: response, options: [])
    return String(data: encoded ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
}

/// Answers unrelated v2 requests so the hook can reach its observable command.
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
