import Foundation
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func readAntigravityHookSession(
        _ sessionId: String,
        context: ClaudeHookContext
    ) throws -> [String: Any] {
        let stateURL = context.root.appendingPathComponent("antigravity-hook-sessions.json")
        let state = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let sessions = try XCTUnwrap(state["sessions"] as? [String: Any])
        return try XCTUnwrap(sessions[sessionId] as? [String: Any])
    }

    func assertActivePromptState(
        _ record: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThan(record["activePromptDepth"] as? Int ?? 0, 0, file: file, line: line)
        XCTAssertEqual(record["agentLifecycle"] as? String, "running", file: file, line: line)
    }
}
