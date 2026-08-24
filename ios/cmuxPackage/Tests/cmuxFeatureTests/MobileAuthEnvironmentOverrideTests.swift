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

    // MARK: - Wholesale explicit choice (Settings backend picker, tri-state)

    /// The staging web origin an explicit staging choice selects.
    private static let stagingOrigin = CMUXBackendEnvironmentOverride.stagingWebOrigin

    @Test func explicitStagingChoiceResolvesStagingBackendInReleaseResolution() {
        // TestFlight/App Store shape: no LocalConfig.plist, nothing baked, a
        // Release build default. The explicit staging choice must flip the
        // whole backend: development Stack project, staging API base, and a
        // staging magic-link callback (WebOriginURL moves both together).
        let overrides = MobileAuthComposition.resolvedOverrides(
            explicitChoice: .staging,
            buildOverrides: MobileAuthComposition.authOverrides(
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

    @Test func laneWithBakesResolvesByteIdentical() {
        // NO explicit choice: the build overrides pass through byte-identical
        // — plain and baked tables alike — so every no-choice install keeps
        // its lane exactly as before the wholesale switcher existed.
        let base = MobileAuthComposition.authOverrides(
            localConfig: [:],
            bakedAuthEnvironment: nil,
            bakedAPIBaseURL: nil
        )
        #expect(MobileAuthComposition.resolvedOverrides(
            explicitChoice: nil,
            buildOverrides: base
        ) == base)

        let baked = MobileAuthComposition.authOverrides(
            localConfig: [:],
            bakedAuthEnvironment: "production",
            bakedAPIBaseURL: "http://localhost:9450"
        )
        #expect(MobileAuthComposition.resolvedOverrides(
            explicitChoice: nil,
            buildOverrides: baked
        ) == baked)
    }

    @Test func explicitProductionChoiceContributesTheFullProductionSetBeatingBakesAndLocalConfig() {
        // An explicit choice is a WHOLESALE override: a fresh three-key table
        // REPLACES the baked Info.plist values AND LocalConfig entries —
        // including LocalConfig STACK_PROJECT_ID_* / publishable-key
        // overrides, which are stripped while a choice is active (the lane
        // position restores their supremacy).
        let buildOverrides = MobileAuthComposition.authOverrides(
            localConfig: [
                "AuthEnvironment": "development",
                "ApiBaseURL": "http://localhost:8123",
                "WebOriginURL": "http://localhost:8123",
                "STACK_PROJECT_ID_PROD": "someone-elses-project",
            ],
            bakedAuthEnvironment: "development",
            bakedAPIBaseURL: "http://localhost:9450"
        )
        let overrides = MobileAuthComposition.resolvedOverrides(
            explicitChoice: .production,
            buildOverrides: buildOverrides
        )
        #expect(overrides == [
            "AuthEnvironment": "production",
            "ApiBaseURL": "https://cmux.com",
            "WebOriginURL": "https://cmux.com",
        ])
        let environment = MobileAuthComposition.resolvedAuthEnvironment(
            isDevelopmentBuild: true,
            overrides: overrides
        )
        #expect(environment == .production)
        let config = AuthConfig(environment: environment, overrides: overrides)
        #expect(config.stack.projectId == Self.productionProjectID)
        #expect(config.apiBaseURL == "https://cmux.com")
        #expect(config.magicLinkCallbackURL == "https://cmux.com/auth/callback")
    }

    @Test func explicitStagingChoiceBeatsAStagingBake() {
        // A staging-baked build (device dev rig) with an EXPLICIT staging
        // choice resolves the same staging table wholesale — and the choice
        // stays DISTINCT from the lane at the selection level, which is what
        // lets the transaction's selection-identity guard accept the
        // device-lane pick (lane(staging) ≠ explicit(staging)).
        let overrides = MobileAuthComposition.resolvedOverrides(
            explicitChoice: .staging,
            buildOverrides: MobileAuthComposition.authOverrides(
                localConfig: [:],
                bakedAuthEnvironment: nil,
                bakedAPIBaseURL: Self.stagingOrigin
            )
        )
        #expect(overrides == [
            "AuthEnvironment": "development",
            "ApiBaseURL": Self.stagingOrigin,
            "WebOriginURL": Self.stagingOrigin,
        ])
    }

    @Test func persistedStagingChoiceFlipsTheComposition() throws {
        // Full composition over injected defaults: the persisted choice is
        // read from the SAME defaults the caches use, resolves the staging
        // backend, and reports the EXPLICIT staging selection.
        let defaults = try freshDefaults()
        CMUXBackendEnvironmentOverride.staging.storeChoice(in: defaults)
        let composition = try makeComposition(
            bundle: fixtureBundle(localConfig: [:]),
            defaults: defaults
        )
        #expect(composition.authEnvironment == .development)
        #expect(composition.config.stack.projectId == Self.developmentProjectID)
        #expect(composition.config.apiBaseURL == Self.stagingOrigin)
        #expect(composition.config.magicLinkCallbackURL == "\(Self.stagingOrigin)/auth/callback")
        #expect(composition.backendEnvironmentSwitch.selection == .explicit(.staging))
        #expect(composition.backendEnvironmentExplicitChoice == .staging)
    }

    @Test func persistedProductionChoiceIsAWholesaleProductionPin() throws {
        // Tri-state persistence: storing production WRITES the key, and an
        // explicit production choice pins the production backend even on a
        // DEBUG (development-lane) build — production Stack project and
        // cmux.com replace the localhost dev defaults. The resolved
        // production channel also disables the dev auto-login for free
        // (includesDevAuth keys on the resolved environment).
        let defaults = try freshDefaults()
        CMUXBackendEnvironmentOverride.production.storeChoice(in: defaults)
        let composition = try makeComposition(
            bundle: fixtureBundle(localConfig: [:]),
            defaults: defaults
        )
        #expect(composition.authEnvironment == .production)
        #expect(composition.config.stack.projectId == Self.productionProjectID)
        #expect(composition.config.apiBaseURL == "https://cmux.com")
        #expect(composition.backendEnvironmentSwitch.selection == .explicit(.production))
        #expect(composition.backendEnvironmentExplicitChoice == .production)
    }

    @Test func unknownPersistedChoiceBehavesAsTheLane() throws {
        // A corrupted or future raw value fails safe toward the build's own
        // bake: it loads as NO choice, so the composition reproduces the
        // untouched build default (tests compile DEBUG: the development
        // project and localhost web origin) and reports the LANE selection.
        let defaults = try freshDefaults()
        defaults.set("qa", forKey: CMUXBackendEnvironmentOverride.defaultsKey)
        let composition = try makeComposition(
            bundle: fixtureBundle(localConfig: [:]),
            defaults: defaults
        )
        #expect(composition.config.stack.projectId == Self.developmentProjectID)
        #expect(composition.config.apiBaseURL == "http://localhost:3000")
        #expect(composition.backendEnvironmentSwitch.selection
            == .lane(resolves: .production))
        #expect(composition.backendEnvironmentExplicitChoice == nil)
    }

    @Test func explicitChoiceBeatsATaggedBuildBake() throws {
        // The former pinned refusal, inverted: a tagged dev build
        // (LocalConfig/Info.plist decides a backend key) no longer blocks the
        // picker — the explicit choice REPLACES the bake wholesale, and the
        // bake survives only as the build's custom LANE descriptor.
        let defaults = try freshDefaults()
        CMUXBackendEnvironmentOverride.staging.storeChoice(in: defaults)
        let composition = try makeComposition(
            bundle: fixtureBundle(localConfig: ["ApiBaseURL": "http://localhost:9450"]),
            defaults: defaults
        )
        #expect(composition.config.apiBaseURL == Self.stagingOrigin)
        #expect(composition.backendEnvironmentSwitch.selection == .explicit(.staging))
        #expect(composition.backendEnvironmentSwitch.buildLane
            == .custom(label: "localhost:9450"))
    }

    // MARK: - Lane classification (the build's own bake)

    @Test func laneClassifiesFromTheBuildOverridesAlone() {
        // Unpinned Release shape → the production lane.
        #expect(MobileAuthComposition.resolvedBackendEnvironmentBuildLane(
            isDevelopmentBuild: false,
            buildOverrides: [:]
        ) == .production)
        // A staging-baked build (device dev rigs) → the staging lane.
        #expect(MobileAuthComposition.resolvedBackendEnvironmentBuildLane(
            isDevelopmentBuild: false,
            buildOverrides: ["ApiBaseURL": Self.stagingOrigin]
        ) == .staging)
        #expect(MobileAuthComposition.resolvedBackendEnvironmentBuildLane(
            isDevelopmentBuild: true,
            buildOverrides: ["ApiBaseURL": Self.stagingOrigin]
        ) == .staging)
        // An untagged Debug build (localhost dev default) → a custom lane
        // labeled with its origin.
        #expect(MobileAuthComposition.resolvedBackendEnvironmentBuildLane(
            isDevelopmentBuild: true,
            buildOverrides: [:]
        ) == .custom(label: "localhost:3000"))
        // A tagged dev build's isolated origin → a custom lane.
        #expect(MobileAuthComposition.resolvedBackendEnvironmentBuildLane(
            isDevelopmentBuild: true,
            buildOverrides: ["ApiBaseURL": "http://localhost:9450"]
        ) == .custom(label: "localhost:9450"))
        // A --prod-auth dev build (production channel + cmux.com bake)
        // resolves cmux.com under the production Stack channel → the
        // production lane, mirroring the macOS classifier.
        #expect(MobileAuthComposition.resolvedBackendEnvironmentBuildLane(
            isDevelopmentBuild: true,
            buildOverrides: [
                "AuthEnvironment": "production",
                "ApiBaseURL": "https://cmux.com",
            ]
        ) == .production)
        // cmux.com on the DEVELOPMENT channel is not the production lane
        // (mixed bake): classify custom so gating and recovery fail safe.
        #expect(MobileAuthComposition.resolvedBackendEnvironmentBuildLane(
            isDevelopmentBuild: true,
            buildOverrides: ["ApiBaseURL": "https://cmux.com"]
        ) == .custom(label: "cmux.com"))
    }

    @Test func laneIgnoresThePersistedExplicitChoice() throws {
        // The lane is a stable property of the installed build: an explicit
        // choice flips the SELECTION and the resolved config, never the lane.
        let defaults = try freshDefaults()
        CMUXBackendEnvironmentOverride.staging.storeChoice(in: defaults)
        let composition = try makeComposition(
            bundle: fixtureBundle(localConfig: [:]),
            defaults: defaults
        )
        // Tests compile DEBUG with no bakes: the localhost custom lane.
        #expect(composition.backendEnvironmentSwitch.buildLane
            == .custom(label: "localhost:3000"))
        #expect(composition.backendEnvironmentSwitch.selection == .explicit(.staging))
    }

    // MARK: - Device clear hook (dev-rig determinism)

    @Test func clearHookReturnsTheBuildToItsLaneAndRemovesBothKeys() throws {
        // scripts/mobile-dev-launch.sh injects
        // CMUX_DEV_CLEAR_BACKEND_ENV_CHOICE=1 on every dev launch: a
        // persisted staging choice (and an armed switch-rebuild marker) from
        // an earlier dogfood round must be cleared BEFORE the choice is
        // read, so the freshly baked build resolves its own lane.
        let defaults = try freshDefaults()
        CMUXBackendEnvironmentOverride.staging.storeChoice(in: defaults)
        CMUXBackendEnvironmentSwitchRebuildMarker.arm(in: defaults)

        let composition = MobileAuthComposition(
            environment: ["CMUX_DEV_CLEAR_BACKEND_ENV_CHOICE": "1"],
            bundle: try fixtureBundle(localConfig: [:]),
            defaults: defaults,
            reachability: OfflineReachabilityStub(),
            policy: .current
        )

        #expect(composition.backendEnvironmentSwitch.selection
            == .lane(resolves: .production))
        #expect(composition.config.apiBaseURL == "http://localhost:3000")
        #expect(defaults.string(forKey: CMUXBackendEnvironmentOverride.defaultsKey) == nil)
        #expect(defaults.object(
            forKey: CMUXBackendEnvironmentSwitchRebuildMarker.defaultsKey
        ) == nil)
    }

    @Test func withoutTheClearHookThePersistedChoiceIsHonored() throws {
        // Control: a normal launch (no hook) keeps the explicit choice.
        let defaults = try freshDefaults()
        CMUXBackendEnvironmentOverride.staging.storeChoice(in: defaults)
        let composition = try makeComposition(
            bundle: fixtureBundle(localConfig: [:]),
            defaults: defaults
        )
        #expect(composition.backendEnvironmentSwitch.selection == .explicit(.staging))
        #expect(defaults.string(
            forKey: CMUXBackendEnvironmentOverride.defaultsKey
        ) == CMUXBackendEnvironmentOverride.staging.rawValue)
    }

    // MARK: - Rebuild without relaunch (the live switch's commit + rebuild)

    @Test func rebuildOverSameDefaultsAppliesStoredStagingChoice() throws {
        // The live switch stores the choice and assembles a SECOND
        // composition over the same defaults suite, in the same process. The
        // new composition must resolve the staging origin + the development
        // Stack project (what the staging web deployment authenticates
        // against) with no relaunch anywhere, and its switch state must
        // report the explicit staging selection so the Settings badge
        // converges by re-injection alone.
        let defaults = try freshDefaults()
        let bundle = try fixtureBundle(localConfig: [:])
        let first = try makeComposition(bundle: bundle, defaults: defaults)
        #expect(first.backendEnvironmentSwitch.selection == .lane(resolves: .production))

        // The transaction's storeSelection (commit) step for an explicit
        // target.
        CMUXBackendEnvironmentOverride.staging.storeChoice(in: defaults)

        let second = try makeComposition(bundle: bundle, defaults: defaults)
        #expect(second.authEnvironment == .development)
        #expect(second.config.stack.projectId == Self.developmentProjectID)
        #expect(second.config.apiBaseURL == Self.stagingOrigin)
        #expect(second.config.magicLinkCallbackURL == "\(Self.stagingOrigin)/auth/callback")
        #expect(second.backendEnvironmentSwitch.selection == .explicit(.staging))

        // And back to the LANE: the storeSelection step for a lane target
        // CLEARS the key, restoring the untouched build default on the next
        // rebuild (tests compile DEBUG: localhost origin).
        CMUXBackendEnvironmentOverride.clearChoice(in: defaults)
        let third = try makeComposition(bundle: bundle, defaults: defaults)
        #expect(third.backendEnvironmentSwitch.selection == .lane(resolves: .production))
        #expect(third.config.apiBaseURL == "http://localhost:3000")
    }

    @Test func rebuildOntoStagingRequestsTheSessionClearOnRelease() throws {
        // Release-shaped project resolution over ONE defaults suite: launch A
        // resolves production (records the production project id), the switch
        // stores staging, and rebuild B resolves the development project — so
        // detectAuthProjectSwitch must request the stale-state clear exactly
        // at the rebuild. (The full-composition variant above cannot show
        // this: tests compile DEBUG, where both resolutions already use the
        // development project.)
        let defaults = try freshDefaults()
        defaults.set(true, forKey: MobileAuthComposition.sessionCacheDefaultsKey)

        let launchOverrides = MobileAuthComposition.authOverrides(
            localConfig: [:],
            bakedAuthEnvironment: nil,
            bakedAPIBaseURL: nil
        )
        let launchProjectID = AuthConfig(
            environment: MobileAuthComposition.resolvedAuthEnvironment(
                isDevelopmentBuild: false,
                overrides: launchOverrides
            ),
            overrides: launchOverrides
        ).stack.projectId
        #expect(MobileAuthComposition.detectAuthProjectSwitch(
            resolvedProjectID: launchProjectID,
            buildDefaultProjectID: Self.productionProjectID,
            defaults: defaults
        ) == false)

        CMUXBackendEnvironmentOverride.staging.storeChoice(in: defaults)
        let rebuiltOverrides = MobileAuthComposition.resolvedOverrides(
            explicitChoice: CMUXBackendEnvironmentOverride.explicitChoice(from: defaults),
            buildOverrides: launchOverrides
        )
        let rebuiltProjectID = AuthConfig(
            environment: MobileAuthComposition.resolvedAuthEnvironment(
                isDevelopmentBuild: false,
                overrides: rebuiltOverrides
            ),
            overrides: rebuiltOverrides
        ).stack.projectId
        #expect(rebuiltProjectID == Self.developmentProjectID)
        #expect(MobileAuthComposition.detectAuthProjectSwitch(
            resolvedProjectID: rebuiltProjectID,
            buildDefaultProjectID: Self.productionProjectID,
            defaults: defaults
        ) == true)
    }

    @Test func stagingSwitchOnReleaseFlipsStackProjectAndRequestsSessionClear() throws {
        // A Release build defaults to the production project; the explicit
        // staging choice resolves the development project, so the existing
        // project-switch detection clears the per-project session state on
        // the first staging launch (tokens/user ids never cross projects).
        let overrides = MobileAuthComposition.resolvedOverrides(
            explicitChoice: .staging,
            buildOverrides: MobileAuthComposition.authOverrides(
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

    // MARK: - Gap-fix heads (broker + presence follow the explicit choice)

    @Test func explicitChoiceHeadsTheBrokerResolutionAboveTheBake() {
        // The baked CMUXIrohBrokerBaseURL is read FIRST in lane resolution;
        // under an explicit choice the broker must follow the chosen backend
        // instead (each environment's web deployment serves its own broker),
        // or a switched build would pair against the rig's baked broker
        // while auth talks to the chosen backend.
        let bakedInfo: [String: Any] = [
            "CMUXIrohBrokerBaseURL": "https://broker.example.dev"
        ]
        #expect(MobileIrohRuntimeComposition.resolvedBrokerBaseURL(
            apiBaseURL: "http://localhost:3000",
            explicitChoice: .production,
            infoDictionary: bakedInfo
        ) == URL(string: "https://cmux.com"))
        #expect(MobileIrohRuntimeComposition.resolvedBrokerBaseURL(
            apiBaseURL: "http://localhost:3000",
            explicitChoice: .staging,
            infoDictionary: bakedInfo
        ) == URL(string: Self.stagingOrigin))
        // NO choice: the bake keeps winning, byte-identical to today.
        #expect(MobileIrohRuntimeComposition.resolvedBrokerBaseURL(
            apiBaseURL: "http://localhost:3000",
            explicitChoice: nil,
            infoDictionary: bakedInfo
        ) == URL(string: "https://broker.example.dev"))
    }

    @Test func explicitChoiceHeadsThePresenceResolutionAboveEnvAndDefaults() throws {
        // Presence env/defaults/bake overrides are the dev-rig isolation
        // mechanism; the explicit choice is a WHOLESALE override and beats
        // them all: explicit staging signs into the dev Stack project, which
        // only the dev/staging worker verifies, and explicit production is
        // the production worker.
        let isolatedWorker = "https://cmux-presence-dev-alice.acct.workers.dev"
        #expect(PresenceClient.resolvedServiceBaseURL(
            environment: [PresenceClient.serviceURLEnvKey: isolatedWorker],
            defaults: try freshDefaults(),
            infoPlistValue: "https://cmux-presence-dev-baked.acct.workers.dev",
            isDebugBuild: true,
            isDevelopmentAuthChannel: false,
            explicitChoice: .staging
        ) == PresenceClient.debugDefaultServiceURL)
        #expect(PresenceClient.resolvedServiceBaseURL(
            environment: [PresenceClient.serviceURLEnvKey: isolatedWorker],
            defaults: try freshDefaults(),
            infoPlistValue: nil,
            isDebugBuild: true,
            isDevelopmentAuthChannel: true,
            explicitChoice: .production
        ) == PresenceClient.productionServiceURL)
        // NO choice: the env override keeps winning, byte-identical.
        #expect(PresenceClient.resolvedServiceBaseURL(
            environment: [PresenceClient.serviceURLEnvKey: isolatedWorker],
            defaults: try freshDefaults(),
            infoPlistValue: nil,
            isDebugBuild: true,
            isDevelopmentAuthChannel: false,
            explicitChoice: nil
        ) == isolatedWorker)
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
