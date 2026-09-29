import CmuxFoundation
import Foundation

actor ReviewPaneCommands: CommandRunning {
    private var calls: [[String]] = []

    func findingsArguments() -> [[String]] { calls.filter { $0.contains("findings") } }

    func run(directory: String, executable: String, arguments: [String], timeout: TimeInterval?) async -> CommandResult {
        calls.append(arguments)
        let payload: [String: Any]
        switch arguments[1] {
        case "list":
            payload = ["reviews": [["id": "receipt", "created_at": "2026-09-25T00:00:00Z"]]]
        case "show":
            payload = ["brief": ["intent": "Fix the caller"], "source": ["tree_sha": "recorded-tree"]]
        default:
            let ids = arguments.contains("--all") ? ["F-1", "F-2"] : ["F-1"]
            payload = ["findings": ids.map { id in
                ["id": id, "title": id, "severity": "P1", "disposition": "human_required",
                 "verification": ["result": "human_judgment"]] as [String: Any]
            }]
        }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return CommandResult(stdout: String(data: data, encoding: .utf8), stderr: nil, exitStatus: 0, timedOut: false, executionError: nil)
    }
}
