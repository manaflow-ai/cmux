import CMUXAuthCore
import CmuxMobileShell
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

    // MARK: - Dev sign-in shortcut gating

    @Test func productionAuthDisablesTheFortyTwoShortcut() {
        // The 42 shortcut signs in with fixed development-project
        // credentials; a --prod-auth build must not expose that
        // known-credential path against the production Stack project.
        #expect(MobileAuthComposition.includesDevAuth(
            policy: MobileAuthBuildPolicy(includesFortyTwoShortcut: true),
            resolvedEnvironment: .production
        ) == false)
    }

    @Test func developmentAuthKeepsTheFortyTwoShortcutWhenThePolicyHasIt() {
        #expect(MobileAuthComposition.includesDevAuth(
            policy: MobileAuthBuildPolicy(includesFortyTwoShortcut: true),
            resolvedEnvironment: .development
        ) == true)
        // Release policy never includes it, whatever the environment.
        #expect(MobileAuthComposition.includesDevAuth(
            policy: MobileAuthBuildPolicy(includesFortyTwoShortcut: false),
            resolvedEnvironment: .development
        ) == false)
    }

    // MARK: - Project-switch detection (stale cross-project auth state)

    private func freshDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "cmux-auth-env-switch-\(UUID().uuidString)"))
    }

    @Test func firstLaunchOfPlainBuildStoresProjectWithoutRequestingClear() throws {
        // Every existing install upgrades with no stored value; when the
        // resolved project matches the build default (no override), the
        // upgrade itself must never sign anyone out.
        let defaults = try freshDefaults()
        defaults.set(true, forKey: MobileAuthComposition.sessionCacheDefaultsKey)
        #expect(MobileAuthComposition.detectAuthProjectSwitch(
            resolvedProjectID: Self.developmentProjectID,
            buildDefaultProjectID: Self.developmentProjectID,
            defaults: defaults
        ) == false)
        #expect(defaults.string(forKey: MobileAuthComposition.storedStackProjectIDKey) == Self.developmentProjectID)
    }

    @Test func firstProdAuthLaunchOverSignedInDevInstallClears() throws {
        // Autoreview regression: no stored project key exists on the first
        // launch of the build that introduced it, but a signed-in dev
        // install's session can only belong to the build-default project —
        // so the first --prod-auth launch must still clear, or the stale
        // dev-project identity primes under production auth and the pairing
        // preflight reads the wrong user id.
        let defaults = try freshDefaults()
        defaults.set(true, forKey: MobileAuthComposition.sessionCacheDefaultsKey)
        #expect(MobileAuthComposition.detectAuthProjectSwitch(
            resolvedProjectID: Self.productionProjectID,
            buildDefaultProjectID: Self.developmentProjectID,
            defaults: defaults
        ) == true)
    }

    @Test func firstProdAuthLaunchOnFreshInstallStillRequestsClear() throws {
        // A fresh-looking container can still hide project-scoped keychain
        // tokens (keychain survives app reinstalls), so a project change
        // always requests the clear — a no-op when nothing is actually
        // stored, and auto-login is unaffected (the clear rides
        // clearStaleAuthOnLaunch, not the UI-test flag).
        let defaults = try freshDefaults()
        #expect(MobileAuthComposition.detectAuthProjectSwitch(
            resolvedProjectID: Self.productionProjectID,
            buildDefaultProjectID: Self.developmentProjectID,
            defaults: defaults
        ) == true)
        #expect(defaults.string(forKey: MobileAuthComposition.storedStackProjectIDKey) == Self.productionProjectID)
    }

    @Test func sameProjectRelaunchDoesNotRequestClear() throws {
        let defaults = try freshDefaults()
        defaults.set(true, forKey: MobileAuthComposition.sessionCacheDefaultsKey)
        _ = MobileAuthComposition.detectAuthProjectSwitch(
            resolvedProjectID: Self.productionProjectID,
            buildDefaultProjectID: Self.developmentProjectID,
            defaults: defaults
        )
        #expect(MobileAuthComposition.detectAuthProjectSwitch(
            resolvedProjectID: Self.productionProjectID,
            buildDefaultProjectID: Self.developmentProjectID,
            defaults: defaults
        ) == false)
    }

    @Test func projectFlipWithLocalAuthStateRequestsClearBothWays() throws {
        // dev -> prod (a --prod-auth rebuild over a signed-in dev install) and
        // prod -> dev must both clear: tokens/user ids are per-Stack-project,
        // so restoring the other project's session can only fail validation
        // and flash the wrong cached user.
        let defaults = try freshDefaults()
        defaults.set(true, forKey: MobileAuthComposition.sessionCacheDefaultsKey)
        _ = MobileAuthComposition.detectAuthProjectSwitch(
            resolvedProjectID: Self.developmentProjectID,
            buildDefaultProjectID: Self.developmentProjectID,
            defaults: defaults
        )
        #expect(MobileAuthComposition.detectAuthProjectSwitch(
            resolvedProjectID: Self.productionProjectID,
            buildDefaultProjectID: Self.developmentProjectID,
            defaults: defaults
        ) == true)
        #expect(MobileAuthComposition.detectAuthProjectSwitch(
            resolvedProjectID: Self.developmentProjectID,
            buildDefaultProjectID: Self.developmentProjectID,
            defaults: defaults
        ) == true)
    }

    @Test func sameEnvironmentProjectIDOverrideChangeStillClears() throws {
        // Autoreview regression: STACK_PROJECT_ID_DEV can repoint the dev
        // channel at another Stack project while the environment label stays
        // "development" — the switch detection must key on the PROJECT ID,
        // not the environment name, or the old project's session survives.
        let defaults = try freshDefaults()
        defaults.set(true, forKey: MobileAuthComposition.sessionCacheDefaultsKey)
        _ = MobileAuthComposition.detectAuthProjectSwitch(
            resolvedProjectID: "personal-dev-project",
            buildDefaultProjectID: "personal-dev-project",
            defaults: defaults
        )
        #expect(MobileAuthComposition.detectAuthProjectSwitch(
            resolvedProjectID: Self.developmentProjectID,
            buildDefaultProjectID: Self.developmentProjectID,
            defaults: defaults
        ) == true)
    }

    @Test func projectFlipAfterSignOutStillRequestsClear() throws {
        // Even signed out (empty defaults caches), the previous project's
        // keychain tokens can linger — the token store is project-scoped and
        // outlives the defaults — so a recorded project change always clears.
        // Auto-login on the same launch is unaffected (covered by
        // AuthCoordinatorEnvironmentSwitchClearTests).
        let defaults = try freshDefaults()
        _ = MobileAuthComposition.detectAuthProjectSwitch(
            resolvedProjectID: Self.developmentProjectID,
            buildDefaultProjectID: Self.developmentProjectID,
            defaults: defaults
        )
        #expect(MobileAuthComposition.detectAuthProjectSwitch(
            resolvedProjectID: Self.productionProjectID,
            buildDefaultProjectID: Self.developmentProjectID,
            defaults: defaults
        ) == true)
    }

    // MARK: - Presence follows the auth channel

    @Test func presenceDefaultFollowsAuthChannelNotBuildConfig() throws {
        // A --prod-auth dev build (Debug config, production channel) must
        // subscribe to the production worker its real Macs heartbeat to; the
        // worker URLs live only in PresenceClient so build scripts cannot
        // bake a stale copy.
        #expect(PresenceClient.resolvedServiceBaseURL(
            environment: [:],
            defaults: try freshDefaults(),
            infoPlistValue: nil,
            isDebugBuild: true,
            isDevelopmentAuthChannel: false
        ) == PresenceClient.productionServiceURL)
        // Plain dev build: unchanged dev worker.
        #expect(PresenceClient.resolvedServiceBaseURL(
            environment: [:],
            defaults: try freshDefaults(),
            infoPlistValue: nil,
            isDebugBuild: true,
            isDevelopmentAuthChannel: true
        ) == PresenceClient.debugDefaultServiceURL)
        // No channel supplied: the pre-existing build-config default.
        #expect(PresenceClient.resolvedServiceBaseURL(
            environment: [:],
            defaults: try freshDefaults(),
            infoPlistValue: nil,
            isDebugBuild: true,
            isDevelopmentAuthChannel: nil
        ) == PresenceClient.debugDefaultServiceURL)
    }

    @Test func explicitPresenceOverrideStillBeatsChannelDefault() throws {
        // Per-developer isolated workers keep working with --prod-auth.
        #expect(PresenceClient.resolvedServiceBaseURL(
            environment: [PresenceClient.serviceURLEnvKey: "https://cmux-presence-dev-alice.acct.workers.dev"],
            defaults: try freshDefaults(),
            infoPlistValue: nil,
            isDebugBuild: true,
            isDevelopmentAuthChannel: false
        ) == "https://cmux-presence-dev-alice.acct.workers.dev")
    }
}
