import CMUXAuthCore
import CmuxMobileTransport
import Foundation
import Testing
@testable import cmuxFeature

/// Offline reachability stub for constructing the auth composition in tests.
/// File-scope (not nested in the suite) so it stays nonisolated: a type nested
/// in the `@MainActor` suite would inherit that isolation and could no longer
/// witness the nonisolated `ReachabilityProviding` requirements.
private struct OfflineReachabilityStub: ReachabilityProviding {
    var isOnline: Bool { false }
    func pathChanges() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/7145:
/// a sideloaded DEBUG (dev-channel) build signs in to the development Stack
/// project, so its user id can never match the production account binding
/// (`ub`) a release Mac stamps into its pairing QR — every prod QR fails the
/// preflight before any route is dialed, even for the same email. The
/// supported fix is running a dev build against production auth through the
/// `AuthEnvironment` override (a `LocalConfig.plist` entry, or the Info.plist
/// value `ios/scripts/reload.sh --prod-auth` bakes). These tests pin that
/// override to the resolved auth configuration.
@MainActor
@Suite struct MobileAuthEnvironmentOverrideTests {
    /// The production Stack project id (`CmuxAuthRuntime.AuthConfig`).
    private static let productionProjectID = "9790718f-14cd-4f7e-824d-eaf527a82b82"
    /// The development Stack project id (`CmuxAuthRuntime.AuthConfig`).
    private static let developmentProjectID = "454ecd03-1db2-4050-845e-4ce5b0cd9895"

    /// Write `localConfig` as `LocalConfig.plist` inside a fresh directory
    /// bundle, mirroring how a build bundles the override plist.
    private func fixtureBundle(localConfig: [String: String]) throws -> Bundle {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-auth-env-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: localConfig,
            format: .xml,
            options: 0
        )
        try data.write(to: directory.appendingPathComponent("LocalConfig.plist"))
        return try #require(Bundle(path: directory.path))
    }

    private func makeComposition(bundle: Bundle) throws -> MobileAuthComposition {
        let defaults = try #require(UserDefaults(suiteName: "cmux-auth-env-tests-\(UUID().uuidString)"))
        return MobileAuthComposition(
            environment: [:],
            bundle: bundle,
            defaults: defaults,
            reachability: OfflineReachabilityStub(),
            policy: .current
        )
    }

    @Test func localConfigProductionOverrideFlipsDevBuildToProductionAuth() throws {
        let bundle = try fixtureBundle(localConfig: ["AuthEnvironment": "production"])
        let composition = try makeComposition(bundle: bundle)

        // A dev build overridden to production auth must resolve the
        // production Stack project and the production web API/callback, or its
        // signed-in user id can never match a release Mac's QR account binding.
        #expect(composition.config.stack.projectId == Self.productionProjectID)
        #expect(composition.config.apiBaseURL == "https://cmux.com")
        #expect(composition.config.magicLinkCallbackURL == "https://cmux.com/auth/callback")
    }

    @Test func missingOverrideKeepsBuildDefaultEnvironment() throws {
        // Control (tests compile DEBUG): without an override the build keeps
        // signing in to the development project, so the localhost/simulator
        // dev workflow is untouched by the override plumbing.
        let bundle = try fixtureBundle(localConfig: [:])
        let composition = try makeComposition(bundle: bundle)

        #expect(composition.config.stack.projectId == Self.developmentProjectID)
        #expect(composition.config.apiBaseURL == "http://localhost:3000")
    }

    @Test func productionOverrideExposesProductionAuthEnvironment() throws {
        // The identity provider labels its user ids with this channel; a
        // --prod-auth build must report production so a pairing user-id
        // mismatch is NOT explained away as a dev-channel artifact.
        let bundle = try fixtureBundle(localConfig: ["AuthEnvironment": "production"])
        let composition = try makeComposition(bundle: bundle)

        #expect(composition.authEnvironment == .production)
    }

    // MARK: - Pure environment resolution

    @Test func overrideWinsOverBuildDefaultInBothDirections() {
        #expect(MobileAuthComposition.resolvedAuthEnvironment(
            isDevelopmentBuild: true,
            overrides: ["AuthEnvironment": "production"]
        ) == .production)
        #expect(MobileAuthComposition.resolvedAuthEnvironment(
            isDevelopmentBuild: false,
            overrides: ["AuthEnvironment": "development"]
        ) == .development)
    }

    @Test func overrideIsCaseInsensitiveAndTrimmed() {
        #expect(MobileAuthComposition.resolvedAuthEnvironment(
            isDevelopmentBuild: true,
            overrides: ["AuthEnvironment": "  Production\n"]
        ) == .production)
    }

    @Test func unrecognizedOverrideKeepsBuildDefault() {
        // Fail toward the channel the build was compiled for: a typo must not
        // silently flip a dev build onto production auth (or vice versa).
        #expect(MobileAuthComposition.resolvedAuthEnvironment(
            isDevelopmentBuild: true,
            overrides: ["AuthEnvironment": "prod"]
        ) == .development)
        #expect(MobileAuthComposition.resolvedAuthEnvironment(
            isDevelopmentBuild: false,
            overrides: ["AuthEnvironment": "staging"]
        ) == .production)
        #expect(MobileAuthComposition.resolvedAuthEnvironment(
            isDevelopmentBuild: true,
            overrides: [:]
        ) == .development)
        #expect(MobileAuthComposition.resolvedAuthEnvironment(
            isDevelopmentBuild: false,
            overrides: [:]
        ) == .production)
    }

    // MARK: - Override sourcing (LocalConfig.plist vs the Info.plist bake)

    @Test func bakedInfoPlistValueFillsInWhenLocalConfigHasNoEntry() {
        // The reload.sh --prod-auth path: no LocalConfig.plist, the channel
        // rides in the Info.plist CMUXAuthEnvironment value.
        let overrides = MobileAuthComposition.authOverrides(
            localConfig: [:],
            bakedAuthEnvironment: "production"
        )
        #expect(overrides["AuthEnvironment"] == "production")
    }

    @Test func localConfigEntryWinsOverBakedValue() {
        // LocalConfig.plist is the deliberate, hand-authored override surface;
        // it beats the script-baked Info.plist value (mirrors presence
        // resolution precedence).
        let overrides = MobileAuthComposition.authOverrides(
            localConfig: ["AuthEnvironment": "development"],
            bakedAuthEnvironment: "production"
        )
        #expect(overrides["AuthEnvironment"] == "development")
    }

    @Test func blankBakedValueContributesNothing() {
        // A normal (non --prod-auth) build expands $(CMUX_IOS_AUTH_ENV) to ""
        // in Info.plist; that empty string must not shadow the build default.
        let overrides = MobileAuthComposition.authOverrides(
            localConfig: [:],
            bakedAuthEnvironment: "  "
        )
        #expect(overrides["AuthEnvironment"] == nil)
    }
}
