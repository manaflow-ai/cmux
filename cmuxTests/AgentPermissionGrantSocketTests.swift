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
        ]
        for index in invalid.indices {
            let result = await TerminalController.shared.v2PermissionsRequest(params: invalid[index])
            #expect(errorCode(result) == "invalid_params", "case \(index)")
        }
    }

    @Test func revokeNeedsAnIdOrAll() {
        for params: [String: Any] in [[:], ["id": "not-a-uuid"], ["all": "yes"]] {
            #expect(errorCode(TerminalController.shared.v2PermissionsRevoke(params: params)) == "invalid_params")
        }
    }
}
