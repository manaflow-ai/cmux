import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class OpenDiffViewerAgentBaselineLocationTests: XCTestCase {
    func testBaselineStoreUsesBundleScopedHookDirectory() {
        let applicationSupport = URL(fileURLWithPath: "/tmp/cmux-test-application-support", isDirectory: true)
        let legacyHome = URL(fileURLWithPath: "/tmp/cmux-test-home", isDirectory: true)

        let resolved = AppDelegate.agentTurnDiffBaselineStoreURLs(
            environment: [:],
            applicationSupportDirectory: applicationSupport,
            bundleIdentifier: "com.cmuxterm.app.nightly",
            legacyHomeDirectory: legacyHome
        )

        XCTAssertEqual(
            resolved,
            [
                applicationSupport
                    .appendingPathComponent("cmux/agent-hooks/com.cmuxterm.app.nightly", isDirectory: true)
                    .appendingPathComponent("agent-turn-diff-baselines.json", isDirectory: false),
                legacyHome
                    .appendingPathComponent(".cmuxterm/agent-turn-diff-baselines.json", isDirectory: false),
            ]
        )
    }

    func testBaselineStoreHonorsExplicitHookStateOverride() {
        let override = "/tmp/cmux-test-explicit-hook-state"

        let resolved = AppDelegate.agentTurnDiffBaselineStoreURLs(
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": override],
            applicationSupportDirectory: URL(fileURLWithPath: "/tmp/cmux-test-application-support"),
            bundleIdentifier: "com.cmuxterm.app.nightly",
            legacyHomeDirectory: URL(fileURLWithPath: "/tmp/cmux-test-home")
        )

        XCTAssertEqual(
            resolved,
            [
                URL(fileURLWithPath: override, isDirectory: true)
                    .appendingPathComponent("agent-turn-diff-baselines.json", isDirectory: false),
            ]
        )
    }

    func testTaggedDebugBaselineStoreDoesNotReadSharedLegacyState() {
        let applicationSupport = URL(fileURLWithPath: "/tmp/cmux-test-application-support", isDirectory: true)

        let resolved = AppDelegate.agentTurnDiffBaselineStoreURLs(
            environment: [:],
            applicationSupportDirectory: applicationSupport,
            bundleIdentifier: "com.cmuxterm.app.dev.baseline",
            legacyHomeDirectory: URL(fileURLWithPath: "/tmp/cmux-test-home", isDirectory: true)
        )

        XCTAssertEqual(
            resolved,
            [
                applicationSupport
                    .appendingPathComponent("cmux/agent-hooks/com.cmuxterm.app.dev.baseline", isDirectory: true)
                    .appendingPathComponent("agent-turn-diff-baselines.json", isDirectory: false),
            ]
        )
    }

    func testLegacyMatchSelectsItsStoreForTheDiffChild() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-diff-baseline-location-\(UUID().uuidString)", isDirectory: true)
        let scopedDirectory = root.appendingPathComponent("scoped", isDirectory: true)
        let legacyDirectory = root.appendingPathComponent("legacy", isDirectory: true)
        let repoDirectory = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: scopedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspaceId = UUID()
        let surfaceId = UUID()
        let sessionId = "legacy-session"
        let scopedStore = scopedDirectory.appendingPathComponent("agent-turn-diff-baselines.json")
        let legacyStore = legacyDirectory.appendingPathComponent("agent-turn-diff-baselines.json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "records": []])
            .write(to: scopedStore, options: .atomic)
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "records": [[
                "workspaceId": workspaceId.uuidString,
                "surfaceId": surfaceId.uuidString,
                "sessionId": sessionId,
                "repoRoot": repoDirectory.path,
                "capturedAt": 1,
            ]],
        ]).write(to: legacyStore, options: .atomic)

        let context = try XCTUnwrap(AppDelegate.latestAgentTurnDiffContext(
            storeURLs: [scopedStore, legacyStore],
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            sessionId: sessionId
        ))
        XCTAssertEqual(context.repoRoot, repoDirectory.path)
        XCTAssertEqual(context.storeURL, legacyStore)

        let environment = AppDelegate.diffViewerProcessEnvironment(
            baseEnvironment: [:],
            socketPath: "/tmp/cmux-test.sock",
            cliURL: URL(fileURLWithPath: "/tmp/cmux-test-cli"),
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            baselineStoreURL: context.storeURL
        )
        XCTAssertEqual(environment["CMUX_AGENT_HOOK_STATE_DIR"], legacyDirectory.path)
    }
}
