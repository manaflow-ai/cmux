import XCTest

final class OpenDiffViewerAgentBaselineLocationTests: XCTestCase {
    func testBaselineStoreUsesBundleScopedHookDirectory() {
        let applicationSupport = URL(fileURLWithPath: "/tmp/cmux-test-application-support", isDirectory: true)
        let legacyHome = URL(fileURLWithPath: "/tmp/cmux-test-home", isDirectory: true)

        let resolved = AppDelegate.agentTurnDiffBaselineStoreURL(
            environment: [:],
            applicationSupportDirectory: applicationSupport,
            bundleIdentifier: "com.cmuxterm.app.nightly",
            legacyHomeDirectory: legacyHome
        )

        XCTAssertEqual(
            resolved,
            applicationSupport
                .appendingPathComponent("cmux/agent-hooks/com.cmuxterm.app.nightly", isDirectory: true)
                .appendingPathComponent("agent-turn-diff-baselines.json", isDirectory: false)
        )
    }

    func testBaselineStoreHonorsExplicitHookStateOverride() {
        let override = "/tmp/cmux-test-explicit-hook-state"

        let resolved = AppDelegate.agentTurnDiffBaselineStoreURL(
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": override],
            applicationSupportDirectory: URL(fileURLWithPath: "/tmp/cmux-test-application-support"),
            bundleIdentifier: "com.cmuxterm.app.nightly",
            legacyHomeDirectory: URL(fileURLWithPath: "/tmp/cmux-test-home")
        )

        XCTAssertEqual(
            resolved,
            URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("agent-turn-diff-baselines.json", isDirectory: false)
        )
    }
}
