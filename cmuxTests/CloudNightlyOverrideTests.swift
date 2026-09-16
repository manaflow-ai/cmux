import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct CloudNightlyOverrideTests {
    private let cloud = CmuxFeatureFlags.cloudMachinesFlag
    private let nightly = CmuxFeatureFlagOverrideCapability(
        bundleIdentifier: "com.cmuxterm.app.nightly", isDebugBuild: false
    )

    @Test(arguments: [
        ("com.cmuxterm.app.nightly", false, true),
        ("com.cmuxterm.app.debug", true, true),
        ("com.cmuxterm.app.debug.issue12705", true, true),
        ("com.cmuxterm.app", false, false),
        ("com.cmuxterm.app", true, false),
        ("com.cmuxterm.app.staging", false, false),
        ("com.cmuxterm.app.debug.issue12705", false, false),
        ("com.cmuxterm.app.nightly-lookalike", false, false),
        ("com.cmuxterm.app.nightly.suffix", false, false),
        ("unknown.NIGHTLY", false, false),
        ("", true, false)
    ])
    func capabilityUsesBuildIdentity(bundleID: String, isDebug: Bool, allowed: Bool) {
        let capability = CmuxFeatureFlagOverrideCapability(
            bundleIdentifier: bundleID, isDebugBuild: isDebug
        )
        #expect(capability.allowsCloudOverride == allowed)
        #expect(capability.policy(for: cloud) == (allowed ? .localFirst : .disabled))
        #expect(capability.policy(for: CmuxFeatureFlags.simulatorFlag) == .remoteFirst)
    }

    @Test(arguments: [false, true])
    func nightlyPickerControlsEitherRemoteValue(remote: Bool) throws {
        let suite = "cmux.cloud.nightly.picker.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let flags = CmuxFeatureFlags(
            defaults: defaults, overrideCapability: nightly, remoteFlagValueProvider: { _ in remote }
        )
        flags.applyLoadedFlags()
        let initial = InternalFlagRowSnapshot(definition: cloud, flags: flags)
        #expect(initial.resolution.allowsLocalOverride)
        #expect(initial.resolution.source == .remote)
        #expect(initial.overrideChoice == .noOverride)
        #expect(initial.overrideNote == String(
            localized: "featureFlags.override.cloudDogfoodNote",
            defaultValue: "Cloud overrides take priority in this Nightly or debug build."
        ))

        for choice in [InternalFlagOverrideChoice.on, .off] {
            flags.setOverride(choice.overrideValue, for: cloud)
            let row = InternalFlagRowSnapshot(definition: cloud, flags: flags)
            #expect(row.overrideChoice == choice)
            #expect(row.resolution.effectiveValue == choice.overrideValue)
            #expect(row.resolution.source == .override)
            #expect(row.sourceTitle == String(localized: "featureFlags.source.override", defaultValue: "Override"))
            #expect(row.resolution.allowsLocalOverride)
            #expect(flags.remoteValue(for: cloud) == remote)
            flags.applyLoadedFlags()
            #expect(flags.resolution(for: cloud) == row.resolution)
        }

        flags.setOverride(InternalFlagOverrideChoice.noOverride.overrideValue, for: cloud)
        let cleared = InternalFlagRowSnapshot(definition: cloud, flags: flags)
        #expect(cleared.overrideChoice == .noOverride)
        #expect(cleared.resolution.source == .remote)
        #expect(cleared.resolution.effectiveValue == remote)
        #expect(cleared.resolution.allowsLocalOverride)
    }

    @Test
    func nightlyOverridesAndClearingPersistAcrossReconstruction() throws {
        let suite = "cmux.cloud.nightly.persistence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let flags = CmuxFeatureFlags(
            defaults: defaults, overrideCapability: nightly, remoteFlagValueProvider: { _ in false }
        )
        flags.applyLoadedFlags()
        flags.setOverride(true, for: cloud)

        let nextDefaults = try #require(UserDefaults(suiteName: suite))
        let relaunched = CmuxFeatureFlags(
            defaults: nextDefaults, overrideCapability: nightly, remoteFlagValueProvider: { _ in nil }
        )
        #expect(relaunched.remoteValue(for: cloud) == false)
        #expect(relaunched.overrideValue(for: cloud) == true)
        #expect(relaunched.isCloudMachinesEnabled)
        relaunched.applyLoadedFlags()
        #expect(relaunched.isCloudMachinesEnabled)
        relaunched.setOverride(nil, for: cloud)

        let cleared = CmuxFeatureFlags(defaults: nextDefaults, overrideCapability: nightly)
        #expect(cleared.overrideValue(for: cloud) == nil)
        #expect(!cleared.isCloudMachinesEnabled)
        cleared.setOverride(true, for: cloud)
        cleared.clearAllOverrides()
        #expect(cleared.overrideValue(for: cloud) == nil)
        #expect(!cleared.isCloudMachinesEnabled)
        let afterClearAll = CmuxFeatureFlags(defaults: nextDefaults, overrideCapability: nightly)
        #expect(afterClearAll.overrideValue(for: cloud) == nil)
        #expect(!afterClearAll.isCloudMachinesEnabled)
    }

    @Test(arguments: [nil, false, true] as [Bool?])
    func stableIgnoresPersistedOverrideAndRejectsWrites(remote: Bool?) throws {
        let suite = "cmux.cloud.stable.override.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dogfood = CmuxFeatureFlags(defaults: defaults, overrideCapability: nightly)
        dogfood.setOverride(true, for: cloud)
        let stable = CmuxFeatureFlags(
            defaults: defaults,
            overrideCapability: .init(bundleIdentifier: "com.cmuxterm.app", isDebugBuild: false),
            remoteFlagValueProvider: { _ in remote }
        )
        stable.applyLoadedFlags()
        let row = InternalFlagRowSnapshot(definition: cloud, flags: stable)
        #expect(!row.resolution.allowsLocalOverride)
        #expect(row.resolution.effectiveValue == (remote ?? false))
        #expect(row.resolution.source == (remote == nil ? .default : .remote))
        #expect(row.overrideNote == String(
            localized: "featureFlags.override.remoteControlledNote",
            defaultValue: "Controlled remotely; local override inactive."
        ))
        stable.setOverride(false, for: cloud)
        #expect(stable.overrideValue(for: cloud) == true)
        stable.clearAllOverrides()
        stable.setOverride(true, for: cloud)
        #expect(stable.overrideValue(for: cloud) == nil)
        #expect(stable.isCloudMachinesEnabled == (remote ?? false))
    }

    @Test
    func overrideDrivesLiveCloudAvailabilityAndKeepsOtherGates() throws {
        let suite = "cmux.cloud.nightly.availability.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let optInKey = BetaFeaturesCatalogSection().cloudMachines.userDefaultsKey
        defaults.set(true, forKey: optInKey)
        let policy = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, _ in nil })
        var remote = false
        let flags = CmuxFeatureFlags(
            defaults: defaults, overrideCapability: nightly, remoteFlagValueProvider: { _ in remote }
        )
        flags.applyLoadedFlags()
        var transitions: [Bool] = []
        let observer = CloudFeatureAvailabilityObserver(
            isEnabled: {
                CloudMachinesFeature.isEnabled(defaults: defaults, policy: policy, remoteEnabled: flags.isCloudMachinesEnabled)
            },
            didChange: { transitions.append($0) }
        )
        flags.setOverride(true, for: cloud)
        flags.setOverride(true, for: cloud)
        #expect(transitions == [false, true])
        flags.setOverride(nil, for: cloud)
        #expect(transitions == [false, true, false])
        flags.setOverride(true, for: cloud)
        flags.clearAllOverrides()
        #expect(transitions == [false, true, false, true, false])

        remote = true
        flags.applyLoadedFlags()
        flags.setOverride(false, for: cloud)
        #expect(Array(transitions.suffix(2)) == [true, false])
        flags.clearAllOverrides()
        #expect(transitions.last == true)
        remote = false
        flags.applyLoadedFlags()
        #expect(transitions.last == false)
        flags.setOverride(true, for: cloud)
        defaults.set(false, forKey: optInKey)
        #expect(!CloudMachinesFeature.isEnabled(defaults: defaults, policy: policy, remoteEnabled: flags.isCloudMachinesEnabled))
        defaults.set(true, forKey: optInKey)
        let managedOff = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, _ in true })
        #expect(!CloudMachinesFeature.isEnabled(defaults: defaults, policy: managedOff, remoteEnabled: flags.isCloudMachinesEnabled))
        withExtendedLifetime(observer) {}
    }

    @Test
    func nightlyExceptionDoesNotOverrideOtherFlags() throws {
        let suite = "cmux.cloud.nightly.scope.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let flags = CmuxFeatureFlags(
            defaults: defaults, overrideCapability: nightly, remoteFlagValueProvider: { _ in false }
        )
        flags.applyLoadedFlags()
        for flag in CmuxFeatureFlags.allFlags where flag.key != cloud.key {
            flags.setOverride(true, for: flag)
            #expect(flags.overrideValue(for: flag) == nil)
            #expect(!flags.effectiveValue(for: flag))
            #expect(!flags.resolution(for: flag).allowsLocalOverride)
        }
    }
}
