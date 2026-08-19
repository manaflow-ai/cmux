import CMUXAuthCore
import CmuxAuthRuntime
import CmuxMobileShell
import CmuxMobileTransport
import Foundation
import StackAuth
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
/// `AuthEnvironment` override still lets a DEV build test production account
/// behavior, but the separate build policy does not let it connect to an
/// official Mac. These tests pin only the auth override to its configuration.
@MainActor
@Suite struct MobileAuthEnvironmentOverrideTests {
    /// The production Stack project id (`CmuxAuthRuntime.AuthConfig`).
    private static let productionProjectID = "9790718f-14cd-4f7e-824d-eaf527a82b82"
    /// The development Stack project id (`CmuxAuthRuntime.AuthConfig`).
    private static let developmentProjectID = "454ecd03-1db2-4050-845e-4ce5b0cd9895"

    @Test func oauthBrowserCookiesAreNeverSharedWithAnotherIOSBuild() {
        #expect(MobileAuthComposition.oauthBrowserSessionPrivacy == .ephemeral)
    }

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

    private func makeComposition(
        bundle: Bundle,
        defaults: UserDefaults? = nil
    ) throws -> MobileAuthComposition {
        let resolvedDefaults = try defaults
            ?? #require(UserDefaults(suiteName: "cmux-auth-env-tests-\(UUID().uuidString)"))
        return MobileAuthComposition(
            environment: [:],
            bundle: bundle,
            defaults: resolvedDefaults,
            reachability: OfflineReachabilityStub(),
            policy: .current
        )
    }

    @Test func localConfigProductionOverrideFlipsDevBuildToProductionAuth() throws {
        let bundle = try fixtureBundle(localConfig: ["AuthEnvironment": "production"])
        let composition = try makeComposition(bundle: bundle)

        // A dev build overridden to production auth must resolve the
        // production Stack project and the production web API/callback.
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

    @Test func taggedBuildBakesItsIsolatedWebOrigin() {
        let overrides = MobileAuthComposition.authOverrides(
            localConfig: [:],
            bakedAuthEnvironment: nil,
            bakedAPIBaseURL: "http://localhost:9450"
        )

        #expect(overrides["ApiBaseURL"] == "http://localhost:9450")
    }

    @Test func localAPIBaseURLWinsOverTaggedBuildBake() {
        let overrides = MobileAuthComposition.authOverrides(
            localConfig: ["ApiBaseURL": "http://localhost:8123"],
            bakedAuthEnvironment: nil,
            bakedAPIBaseURL: "http://localhost:9450"
        )

        #expect(overrides["ApiBaseURL"] == "http://localhost:8123")
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

    @Test func productionAuthCannotReplaceStoredSessionFromDevMarkers() {
        let environment = [
            "CMUX_DEV_AUTH_REPLACE_SESSION": "1",
            "CMUX_UITEST_STACK_EMAIL": "production@example.com",
            "CMUX_UITEST_STACK_PASSWORD": "password",
        ]

        #expect(!MobileAuthComposition.shouldReplaceStoredSessionWithAutoLogin(
            includesDevAuth: false,
            environment: environment
        ))
        #expect(MobileAuthComposition.shouldReplaceStoredSessionWithAutoLogin(
            includesDevAuth: true,
            environment: environment
        ))
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

    // MARK: - Runtime backend override (Settings Production/Staging picker)

    /// The staging web origin the runtime override selects.
    private static let stagingOrigin = CMUXBackendEnvironmentOverride.stagingWebOrigin

    @Test func persistedStagingOverrideResolvesStagingBackendInReleaseResolution() {
        // TestFlight/App Store shape: no LocalConfig.plist, nothing baked, a
        // Release build default. The persisted staging override must flip the
        // whole backend: development Stack project, staging API base, and a
        // staging magic-link callback (WebOriginURL moves both together).
        let overrides = MobileAuthComposition.mergingRuntimeBackendOverride(
            .staging,
            into: MobileAuthComposition.authOverrides(
                localConfig: [:],
                bakedAuthEnvironment: nil,
                bakedAPIBaseURL: nil
            )
        )
        let environment = MobileAuthComposition.resolvedAuthEnvironment(
            isDevelopmentBuild: false,
            overrides: overrides
        )
        #expect(environment == .development)
        let config = AuthConfig(environment: environment, overrides: overrides)
        #expect(config.stack.projectId == Self.developmentProjectID)
        #expect(config.apiBaseURL == Self.stagingOrigin)
        #expect(config.magicLinkCallbackURL == "\(Self.stagingOrigin)/auth/callback")
    }

    @Test func bakedInfoPlistValuesBeatTheRuntimeStagingOverride() {
        // Baked values are the tagged-dev-build isolation mechanism; a
        // persisted staging override merges only into keys nothing decides.
        let overrides = MobileAuthComposition.mergingRuntimeBackendOverride(
            .staging,
            into: MobileAuthComposition.authOverrides(
                localConfig: [:],
                bakedAuthEnvironment: "production",
                bakedAPIBaseURL: "http://localhost:9450"
            )
        )
        #expect(overrides["AuthEnvironment"] == "production")
        #expect(overrides["ApiBaseURL"] == "http://localhost:9450")
    }

    @Test func localConfigBeatsBakeAndRuntimeOverride() {
        // The full per-key precedence: LocalConfig.plist > baked Info.plist >
        // runtime override > build default.
        let overrides = MobileAuthComposition.mergingRuntimeBackendOverride(
            .staging,
            into: MobileAuthComposition.authOverrides(
                localConfig: [
                    "AuthEnvironment": "production",
                    "ApiBaseURL": "http://localhost:8123",
                    "WebOriginURL": "http://localhost:8123",
                ],
                bakedAuthEnvironment: "development",
                bakedAPIBaseURL: "http://localhost:9450"
            )
        )
        #expect(overrides["AuthEnvironment"] == "production")
        #expect(overrides["ApiBaseURL"] == "http://localhost:8123")
        #expect(overrides["WebOriginURL"] == "http://localhost:8123")
    }

    @Test func productionRuntimeOverrideContributesNothing() {
        // "No key" and production are indistinguishable by design, so a
        // production override must leave the table byte-identical.
        let base = MobileAuthComposition.authOverrides(
            localConfig: [:],
            bakedAuthEnvironment: nil,
            bakedAPIBaseURL: nil
        )
        #expect(MobileAuthComposition.mergingRuntimeBackendOverride(.production, into: base) == base)

        let baked = MobileAuthComposition.authOverrides(
            localConfig: [:],
            bakedAuthEnvironment: "production",
            bakedAPIBaseURL: "http://localhost:9450"
        )
        #expect(MobileAuthComposition.mergingRuntimeBackendOverride(.production, into: baked) == baked)
    }

    @Test func persistedStagingOverrideFlipsTheComposition() throws {
        // Full composition over injected defaults: the persisted override is
        // read from the SAME defaults the caches use, resolves the staging
        // backend, and reports staging as both ACTIVE and PENDING (no
        // relaunch divergence right after a staging launch).
        let defaults = try freshDefaults()
        CMUXBackendEnvironmentOverride.staging.store(in: defaults)
        let composition = try makeComposition(
            bundle: fixtureBundle(localConfig: [:]),
            defaults: defaults
        )
        #expect(composition.authEnvironment == .development)
        #expect(composition.config.stack.projectId == Self.developmentProjectID)
        #expect(composition.config.apiBaseURL == Self.stagingOrigin)
        #expect(composition.config.magicLinkCallbackURL == "\(Self.stagingOrigin)/auth/callback")
        #expect(composition.backendEnvironmentSwitch.active == .staging)
        #expect(composition.backendEnvironmentSwitch.pending == .staging)
        #expect(!composition.backendEnvironmentSwitch.isPinnedByBuild)
    }

    @Test func productionPersistedOverrideKeepsTodaysResolution() throws {
        // Storing production removes the key; either way the composition must
        // reproduce the untouched build default (tests compile DEBUG, so the
        // development project and localhost web origin).
        let defaults = try freshDefaults()
        CMUXBackendEnvironmentOverride.production.store(in: defaults)
        let composition = try makeComposition(
            bundle: fixtureBundle(localConfig: [:]),
            defaults: defaults
        )
        #expect(composition.config.stack.projectId == Self.developmentProjectID)
        #expect(composition.config.apiBaseURL == "http://localhost:3000")
        #expect(composition.backendEnvironmentSwitch.active == .production)
        #expect(composition.backendEnvironmentSwitch.pending == .production)
    }

    @Test func unknownPersistedOverrideBehavesAsProduction() throws {
        // A corrupted or future raw value must never strand the build on a
        // non-production backend: it loads as production and changes nothing.
        let defaults = try freshDefaults()
        defaults.set("qa", forKey: CMUXBackendEnvironmentOverride.defaultsKey)
        let composition = try makeComposition(
            bundle: fixtureBundle(localConfig: [:]),
            defaults: defaults
        )
        #expect(composition.config.stack.projectId == Self.developmentProjectID)
        #expect(composition.config.apiBaseURL == "http://localhost:3000")
        #expect(composition.backendEnvironmentSwitch.active == .production)
        #expect(composition.backendEnvironmentSwitch.pending == .production)
    }

    @Test func bakedBuildReportsPinnedBackendEnvironment() throws {
        // A tagged dev build (LocalConfig/Info.plist decides a backend key)
        // reports the pin so Settings explains it instead of showing a picker
        // that cannot steer the build; the baked origin still wins.
        let defaults = try freshDefaults()
        CMUXBackendEnvironmentOverride.staging.store(in: defaults)
        let composition = try makeComposition(
            bundle: fixtureBundle(localConfig: ["ApiBaseURL": "http://localhost:9450"]),
            defaults: defaults
        )
        #expect(composition.backendEnvironmentSwitch.isPinnedByBuild)
        #expect(composition.config.apiBaseURL == "http://localhost:9450")
        #expect(composition.backendEnvironmentSwitch.active == .production)
    }

    @Test func backendSwitchStateWritesThePendingOverrideWithoutChangingActive() throws {
        // The Settings picker persists for the NEXT launch; the running
        // process keeps its startup resolution (iOS apps never self-restart).
        let defaults = try freshDefaults()
        let composition = try makeComposition(
            bundle: fixtureBundle(localConfig: [:]),
            defaults: defaults
        )
        composition.backendEnvironmentSwitch.setPending(.staging)
        #expect(composition.backendEnvironmentSwitch.pending == .staging)
        #expect(composition.backendEnvironmentSwitch.active == .production)
        composition.backendEnvironmentSwitch.setPending(.production)
        #expect(composition.backendEnvironmentSwitch.pending == .production)
        // Production removes the key, keeping "no key" == production.
        #expect(defaults.string(forKey: CMUXBackendEnvironmentOverride.defaultsKey) == nil)
    }

    @Test func stagingSwitchOnReleaseFlipsStackProjectAndRequestsSessionClear() throws {
        // A Release build defaults to the production project; the staging
        // override resolves the development project, so the existing
        // project-switch detection clears the per-project session state on
        // the first staging launch (tokens/user ids never cross projects).
        let overrides = MobileAuthComposition.mergingRuntimeBackendOverride(
            .staging,
            into: MobileAuthComposition.authOverrides(
                localConfig: [:],
                bakedAuthEnvironment: nil,
                bakedAPIBaseURL: nil
            )
        )
        let resolvedProjectID = AuthConfig(
            environment: MobileAuthComposition.resolvedAuthEnvironment(
                isDevelopmentBuild: false,
                overrides: overrides
            ),
            overrides: overrides
        ).stack.projectId
        let buildDefaultProjectID = AuthConfig(
            environment: .production,
            overrides: overrides
        ).stack.projectId
        #expect(resolvedProjectID == Self.developmentProjectID)
        #expect(buildDefaultProjectID == Self.productionProjectID)

        let defaults = try freshDefaults()
        defaults.set(true, forKey: MobileAuthComposition.sessionCacheDefaultsKey)
        #expect(MobileAuthComposition.detectAuthProjectSwitch(
            resolvedProjectID: resolvedProjectID,
            buildDefaultProjectID: buildDefaultProjectID,
            defaults: defaults
        ) == true)
    }

    @Test func activeBackendEnvironmentTracksTheResolvedOrigin() {
        #expect(MobileAuthComposition.activeBackendEnvironment(
            resolvedAPIBaseURL: CMUXBackendEnvironmentOverride.stagingWebOrigin
        ) == .staging)
        #expect(MobileAuthComposition.activeBackendEnvironment(
            resolvedAPIBaseURL: "https://cmux.com"
        ) == .production)
        #expect(MobileAuthComposition.activeBackendEnvironment(
            resolvedAPIBaseURL: "http://localhost:3000"
        ) == .production)
    }

    // MARK: - Presence follows the auth channel

    @Test func presenceDefaultFollowsAuthChannelNotBuildConfig() throws {
        // A --prod-auth dev build (Debug config, production channel) must use
        // the worker that accepts its production token. Build compatibility
        // filters the returned Mac instances separately.
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
