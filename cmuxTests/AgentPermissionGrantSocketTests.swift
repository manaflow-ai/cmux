import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Invalid `permissions.*` requests are rejected before any approval panel
/// appears or the grant store is touched.
@MainActor
@Suite("Agent permission grant socket validation")
struct AgentPermissionGrantSocketTests {
    private func errorCode(_ result: TerminalController.V2CallResult) -> String? {
        if case .err(let code, _, _) = result { return code }
        return nil
    }

    @Test func invalidRequestsNeverReachTheUser() async {
        let invalid: [[String: Any]] = [
            [:],
            ["rules": [String](), "scope": "session", "session_id": "s"],
            ["rules": ["Bash(git:*"], "scope": "session", "session_id": "s"],
            ["rules": ["Bash(git:*)"], "scope": "group"],
            ["rules": ["Bash(git:*)"], "scope": "session"],
            ["rules": ["Bash(git:*)"], "scope": "project", "root": "relative/dir"],
            ["rules": ["Bash(git:*)"], "scope": "session", "session_id": "s", "expires_in_seconds": 1],
            ["rules": ["Write"], "scope": "session", "session_id": "s"],
            ["rules": ["Bash(git status)"], "scope": "session", "session_id": "s", "reason": "ok\u{202E}"],
        ]
        for index in invalid.indices {
            let result = await TerminalController.shared.v2PermissionsRequest(params: invalid[index])
            #expect(errorCode(result) == "invalid_params", "case \(index)")
        }
    }

    @Test func matchAnswersOnlyAllowOrNoMatch() throws {
        let result = TerminalController.shared.v2PermissionsMatch(params: [
            "tool_name": "Bash",
            "tool_input": ["command": "git status"],
            "cwd": "/",
            "session_id": "no-grant-\(UUID().uuidString)",
        ])
        guard case .ok(let payload) = result else {
            Issue.record("permissions.match failed: \(result)")
            return
        }
        let answer = try #require(payload as? [String: Any])
        #expect(answer.keys.sorted() == ["allow"])
        #expect(answer["allow"] as? Bool == false)
    }

    @Test func revokeNeedsAnIdOrAll() {
        for params: [String: Any] in [[:], ["id": "not-a-uuid"], ["all": "yes"]] {
            #expect(errorCode(TerminalController.shared.v2PermissionsRevoke(params: params)) == "invalid_params")
        }
    }
}
