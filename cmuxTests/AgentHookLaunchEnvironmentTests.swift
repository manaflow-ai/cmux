import Foundation
import Testing

@testable import cmux

/// Launch-side hook ingest wiring (docs/agent-conversation-protocol.md,
/// "Hook ingest"): the ingest socket path must be tag-scoped for non-stable
/// builds so a tagged dev app never feeds (or steals) the user's stable
/// daemon, and the launch environment must be withheld entirely when no
/// staged cmuxd-remote binary exists so agent launches never depend on the
/// feature.
@Suite struct AgentHookLaunchEnvironmentTests {
    @Test func stableReleaseBuildUsesDocumentedDefaultPath() {
        let path = AgentHookLaunchEnvironment.ingestSocketPath(
            environment: [:],
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            uid: 501
        )
        #expect(path == "/tmp/cmuxd-agentconv-501/ingest.sock")
    }

    @Test func taggedDevBundleGetsTagSuffixedPath() {
        let path = AgentHookLaunchEnvironment.ingestSocketPath(
            environment: [:],
            bundleIdentifier: "com.cmuxterm.app.debug.my-tag",
            isDebugBuild: true,
            uid: 501
        )
        #expect(path == "/tmp/cmuxd-agentconv-501-debug-my-tag/ingest.sock")
    }

    @Test func launchTagScopesBaseDebugBundle() {
        let path = AgentHookLaunchEnvironment.ingestSocketPath(
            environment: ["CMUX_TAG": "Fix Zsh"],
            bundleIdentifier: "com.cmuxterm.app.debug",
            isDebugBuild: true,
            uid: 501
        )
        #expect(path == "/tmp/cmuxd-agentconv-501-debug-fix-zsh/ingest.sock")
    }

    @Test func untaggedDebugBuildStillAvoidsTheStablePath() {
        let path = AgentHookLaunchEnvironment.ingestSocketPath(
            environment: [:],
            bundleIdentifier: "com.cmuxterm.app.debug",
            isDebugBuild: true,
            uid: 501
        )
        #expect(path == "/tmp/cmuxd-agentconv-501-debug/ingest.sock")
    }

    @Test func debugCompileOfStableBundleAvoidsTheStablePath() {
        // A DEBUG build with the stable bundle id (unit test hosts) must not
        // collide with the user's stable daemon either.
        let path = AgentHookLaunchEnvironment.ingestSocketPath(
            environment: [:],
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: true,
            uid: 501
        )
        #expect(path == "/tmp/cmuxd-agentconv-501-debug/ingest.sock")
    }

    @Test func nightlyAndStagingBundlesGetVariantScopedPaths() {
        #expect(AgentHookLaunchEnvironment.ingestSocketPath(
            environment: [:],
            bundleIdentifier: "com.cmuxterm.app.nightly",
            isDebugBuild: false,
            uid: 501
        ) == "/tmp/cmuxd-agentconv-501-nightly/ingest.sock")
        #expect(AgentHookLaunchEnvironment.ingestSocketPath(
            environment: [:],
            bundleIdentifier: "com.cmuxterm.app.staging.rc1",
            isDebugBuild: false,
            uid: 501
        ) == "/tmp/cmuxd-agentconv-501-staging-rc1/ingest.sock")
    }

    @Test func explicitEnvironmentOverrideWins() {
        let path = AgentHookLaunchEnvironment.ingestSocketPath(
            environment: ["CMUX_AGENT_HOOK_SOCKET": "/tmp/custom/ingest.sock"],
            bundleIdentifier: "com.cmuxterm.app.debug.my-tag",
            isDebugBuild: true,
            uid: 501
        )
        #expect(path == "/tmp/custom/ingest.sock")
    }

    @Test func explicitOverrideBinaryIsAlwaysInjectable() {
        let url = URL(fileURLWithPath: "/dev-build/cmuxd-remote")
        for isDebugBuild in [true, false] {
            #expect(AgentHookLaunchEnvironment.injectableEmitBinaryURL(
                outcome: .found(url, .explicitOverride),
                appVersion: "0.50.0",
                environment: [:],
                bundleIdentifier: "com.cmuxterm.app.debug.my-tag",
                isDebugBuild: isDebugBuild
            ) == url)
        }
    }

    @Test func cachedBinaryRequiresExactOrNewerVersionOnStableReleaseBuilds() {
        let url = URL(fileURLWithPath: "/cache/cmuxd-remote")
        // Same release version: same-SHA artifacts, carries the verb.
        #expect(AgentHookLaunchEnvironment.injectableEmitBinaryURL(
            outcome: .found(url, .cached(version: "0.50.0")),
            appVersion: "0.50.0",
            environment: [:],
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false
        ) == url)
        // Newer cached daemon: the verb is additive.
        #expect(AgentHookLaunchEnvironment.injectableEmitBinaryURL(
            outcome: .found(url, .cached(version: "0.51.0")),
            appVersion: "0.50.0",
            environment: [:],
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false
        ) == url)
        // Older cached daemon predates the verb: invoking it would fall
        // through to its CLI dispatch and fail every Claude hook.
        #expect(AgentHookLaunchEnvironment.injectableEmitBinaryURL(
            outcome: .found(url, .cached(version: "0.49.0")),
            appVersion: "0.50.0",
            environment: [:],
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false
        ) == nil)
    }

    @Test func nonStableVariantsInjectOnlyTheExplicitOverride() {
        // Debug, nightly, and staging builds share marketing versions with
        // stable artifacts built from different SHAs, so a cached binary is
        // never provably verb-capable there.
        let url = URL(fileURLWithPath: "/cache/cmuxd-remote")
        let cases: [(bundleIdentifier: String, isDebugBuild: Bool)] = [
            ("com.cmuxterm.app", true),
            ("com.cmuxterm.app.debug.my-tag", true),
            ("com.cmuxterm.app.nightly", false),
            ("com.cmuxterm.app.staging.rc1", false),
        ]
        for testCase in cases {
            #expect(AgentHookLaunchEnvironment.injectableEmitBinaryURL(
                outcome: .found(url, .cached(version: "0.50.0")),
                appVersion: "0.50.0",
                environment: [:],
                bundleIdentifier: testCase.bundleIdentifier,
                isDebugBuild: testCase.isDebugBuild
            ) == nil, "\(testCase.bundleIdentifier) debug=\(testCase.isDebugBuild)")
        }
    }

    @Test func unavailableOutcomeIsNeverInjectable() {
        #expect(AgentHookLaunchEnvironment.injectableEmitBinaryURL(
            outcome: .unavailable(detail: "not cached"),
            appVersion: "0.50.0",
            environment: [:],
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false
        ) == nil)
    }

    @Test func launchEnvironmentIsWithheldWithoutAStagedBinary() {
        // No cached cmuxd-remote: no env vars, so the wrappers skip
        // injection entirely and agent launches are unaffected.
        #expect(AgentHookLaunchEnvironment.launchEnvironment(
            emitBinaryURL: nil,
            socketPath: "/tmp/cmuxd-agentconv-501/ingest.sock"
        ) == nil)
    }

    @Test func launchEnvironmentCarriesEmitBinaryAndSocket() {
        let pairs = AgentHookLaunchEnvironment.launchEnvironment(
            emitBinaryURL: URL(fileURLWithPath: "/cache/remote-daemons/0.1.0/darwin-arm64/cmuxd-remote"),
            socketPath: "/tmp/cmuxd-agentconv-501-debug-my-tag/ingest.sock"
        )
        #expect(pairs?.count == 2)
        #expect(pairs?.first(where: { $0.key == "CMUX_AGENT_HOOK_EMIT_BIN" })?.value
            == "/cache/remote-daemons/0.1.0/darwin-arm64/cmuxd-remote")
        #expect(pairs?.first(where: { $0.key == "CMUX_AGENT_HOOK_SOCKET" })?.value
            == "/tmp/cmuxd-agentconv-501-debug-my-tag/ingest.sock")
    }

    @Test func daemonChildEnvironmentPinsTheSocketPath() {
        // The spawned `cmuxd-remote serve --stdio` child must listen on the
        // same socket the launch wrappers emit to, even when the app
        // environment lacks the key.
        let environment = AgentHookLaunchEnvironment.daemonChildEnvironment(base: ["PATH": "/usr/bin"])
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["CMUX_AGENT_HOOK_SOCKET"]?.isEmpty == false)
        #expect(environment["CMUX_AGENT_HOOK_SOCKET"]?.hasSuffix("/ingest.sock") == true)
    }

    @Test func daemonChildEnvironmentHonorsAnExistingOverride() {
        let environment = AgentHookLaunchEnvironment.daemonChildEnvironment(
            base: ["CMUX_AGENT_HOOK_SOCKET": "/tmp/custom/ingest.sock"]
        )
        #expect(environment["CMUX_AGENT_HOOK_SOCKET"] == "/tmp/custom/ingest.sock")
    }
}
