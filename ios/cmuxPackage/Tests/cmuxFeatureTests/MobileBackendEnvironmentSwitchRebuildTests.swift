import CMUXAuthCore
import CmuxAuthRuntime
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

/// The backend-environment-switch rebuild must RESTORE the target's parked
/// session instead of clearing it, while an organic Stack-project flip (a
/// tagged Debug bundle rebaked with different auth) keeps today's pinned
/// clear semantics. The switch transaction arms
/// `CMUXBackendEnvironmentSwitchRebuildMarker` inside every `storeSelection`
/// step (explicit stores and lane clears alike, including a revert's), and
/// the composition consumes it where `clearStaleAuthOnLaunch` is computed —
/// `detectAuthProjectSwitch` still RUNS (it must update the stored project
/// id); only its verdict is suppressed, exactly once.
@MainActor
@Suite struct MobileBackendEnvironmentSwitchRebuildTests {
    /// The production Stack project id (`CmuxAuthRuntime.AuthConfig`).
    private static let productionProjectID = "9790718f-14cd-4f7e-824d-eaf527a82b82"
    /// The development Stack project id (`CmuxAuthRuntime.AuthConfig`).
    private static let developmentProjectID = "454ecd03-1db2-4050-845e-4ce5b0cd9895"

    private func freshDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "cmux-backend-switch-rebuild-\(UUID().uuidString)"))
    }

    /// Write `localConfig` as `LocalConfig.plist` inside a fresh directory
    /// bundle, mirroring how a build bundles the override plist.
    private func fixtureBundle(localConfig: [String: String]) throws -> Bundle {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-backend-switch-fixture-\(UUID().uuidString)", isDirectory: true)
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
        defaults: UserDefaults
    ) -> MobileAuthComposition {
        MobileAuthComposition(
            environment: [:],
            bundle: bundle,
            defaults: defaults,
            reachability: OfflineReachabilityStub(),
            policy: .current
        )
    }

    // MARK: - The clear verdict seam

    @Test func organicProjectFlipStillRequestsTheClear() throws {
        // Pinned semantics: a project flip with NO armed marker (a
        // rebaked tagged build, a STACK_PROJECT_ID_* change) always clears.
        let defaults = try freshDefaults()
        #expect(MobileAuthComposition.resolvedClearStaleAuthOnLaunch(
            authProjectSwitched: true,
            defaults: defaults
        ))
    }

    @Test func armedMarkerSuppressesTheSwitchRebuildClearExactlyOnce() throws {
        let defaults = try freshDefaults()
        // The transaction's storeSelection step armed the marker; the rebuild
        // over the flipped project must NOT clear (it must restore the
        // target's parked slot instead).
        CMUXBackendEnvironmentSwitchRebuildMarker.arm(in: defaults)
        #expect(!MobileAuthComposition.resolvedClearStaleAuthOnLaunch(
            authProjectSwitched: true,
            defaults: defaults
        ))
        // Exactly once: the very next organic flip keeps today's clear.
        #expect(MobileAuthComposition.resolvedClearStaleAuthOnLaunch(
            authProjectSwitched: true,
            defaults: defaults
        ))
    }

    @Test func markerIsConsumedEvenWhenNoProjectSwitchHappened() throws {
        // A crash after arm can land on a launch whose project did not
        // change (production→production revert). The marker must still be
        // consumed so it cannot leak into a later organic flip.
        let defaults = try freshDefaults()
        CMUXBackendEnvironmentSwitchRebuildMarker.arm(in: defaults)
        #expect(!MobileAuthComposition.resolvedClearStaleAuthOnLaunch(
            authProjectSwitched: false,
            defaults: defaults
        ))
        #expect(defaults.object(
            forKey: CMUXBackendEnvironmentSwitchRebuildMarker.defaultsKey
        ) == nil)
    }

    // MARK: - Full composition over one defaults suite

    @Test func compositionWithArmedMarkerConsumesItAndStillRecordsTheProject() throws {
        // Building the composition is the consumer: after init the marker is
        // gone from the suite (one arm suppresses exactly one composition
        // pass), and detectAuthProjectSwitch still RAN — the stored project
        // id reflects this pass's resolution.
        let defaults = try freshDefaults()
        let bundle = try fixtureBundle(localConfig: [:])
        CMUXBackendEnvironmentSwitchRebuildMarker.arm(in: defaults)

        let composition = makeComposition(bundle: bundle, defaults: defaults)

        #expect(defaults.object(
            forKey: CMUXBackendEnvironmentSwitchRebuildMarker.defaultsKey
        ) == nil)
        #expect(defaults.string(
            forKey: MobileAuthComposition.storedStackProjectIDKey
        ) == composition.config.stack.projectId)
    }

    // MARK: - Release-shaped staging switch (the scenario the marker exists for)

    @Test func stagingSwitchRebuildWithArmedMarkerSuppressesTheClearWhileAnOrganicFlipStillClears() throws {
        // Release-shaped project resolution over ONE defaults suite: launch A
        // resolves production, the switch transaction stores staging AND
        // arms the marker (its storeOverride step), and rebuild B resolves
        // the development project — a genuine project switch whose clear the
        // marker must suppress, so the parked staging slot survives to be
        // restored. (Tests compile DEBUG, so the full-composition variant
        // cannot show this; this mirrors the release resolution exactly like
        // MobileAuthEnvironmentOverrideTests.rebuildOntoStagingRequestsTheSessionClearOnRelease.)
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

        // The transaction's storeSelection (commit) step: choice + marker.
        CMUXBackendEnvironmentOverride.staging.storeChoice(in: defaults)
        CMUXBackendEnvironmentSwitchRebuildMarker.arm(in: defaults)

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
        let projectSwitched = MobileAuthComposition.detectAuthProjectSwitch(
            resolvedProjectID: rebuiltProjectID,
            buildDefaultProjectID: Self.productionProjectID,
            defaults: defaults
        )
        #expect(projectSwitched)

        // The switch rebuild: the project DID flip, but the armed marker
        // suppresses the clear so the parked slot restores.
        #expect(MobileAuthComposition.resolvedClearStaleAuthOnLaunch(
            authProjectSwitched: projectSwitched,
            defaults: defaults
        ) == false)

        // The next organic flip (no marker) keeps today's clear semantics.
        #expect(MobileAuthComposition.detectAuthProjectSwitch(
            resolvedProjectID: Self.productionProjectID,
            buildDefaultProjectID: Self.productionProjectID,
            defaults: defaults
        ))
        #expect(MobileAuthComposition.resolvedClearStaleAuthOnLaunch(
            authProjectSwitched: true,
            defaults: defaults
        ))
    }
}
