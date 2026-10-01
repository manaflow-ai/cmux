import Foundation
import Testing

extension CLINotifyProcessIntegrationRegressionTests {
    func codexLaunchEnvironment(
        context: ClaudeHookContext,
        sessionId _: String,
        observedHookPID: String? = nil
    ) -> [String: String] {
        var environment = agentLaunchEnvironment(
            context: context,
            kind: "codex",
            executable: "/usr/local/bin/codex",
            arguments: ["/usr/local/bin/codex", "--model", "gpt-5.4"]
        )
        if let observedHookPID {
            environment["CMUX_CODEX_HOOK_PID"] = observedHookPID
        }
        return environment
    }

    // A CLI that printed nothing or non-JSON is an ordinary assertion failure.
    // Letting `JSONSerialization` throw here made XCTest record a thrown error,
    // which the CI classifier counts as "unexpected" and treats like an
    // app-host crash, so one slow CLI turned a whole tolerant shard red.
    func notificationRows(from stdout: String) throws -> [[String: Any]] {
        let data = Data(stdout.utf8)
        return try #require(
            (try? JSONSerialization.jsonObject(with: data, options: [])) as? [[String: Any]],
            "Expected notification JSON array, got: \(stdout)"
        )
    }
    func jsonPayload(from stdout: String) throws -> [String: Any] {
        let data = Data(stdout.utf8)
        return try #require(
            (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
            "Expected JSON object, got: \(stdout)"
        )
    }
}
