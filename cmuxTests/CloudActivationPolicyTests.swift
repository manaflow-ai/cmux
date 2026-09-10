import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The one launch-time decision for Cloud, as behavior: a Mac that never opted
/// in and never had a machine is inert (no fleet polling, no tunnel start, no
/// NetworkExtension preferences read); the Beta Features toggle plus a machine
/// admits the tunnel; prior Cloud use on this Mac keeps its fleet alive but
/// never opens the tunnel without the toggle.
@Suite
struct CloudActivationPolicyTests {
    private func policy(
        enabled: Bool,
        usedCloud: Bool = false,
        machine: Bool?,
        configured: Bool,
        resolved: Bool? = nil
    ) -> CloudActivationPolicy {
        CloudActivationPolicy(
            isCloudMachinesEnabled: { enabled },
            hasUsedCloud: { usedCloud },
            hasCloudMachine: { machine },
            isTunnelConfigured: { configured },
            resolveCloudMachine: { resolved }
        )
    }

    @Test("a fresh install is inert: no background work, no adoption, every start refused")
    func freshInstallIsInert() async {
        let policy = policy(enabled: false, machine: nil, configured: false)
        #expect(policy.allowsBackgroundCloudWork == false)
        #expect(policy.allowsLaunchTimeTunnelAdoption == false)
        #expect(policy.tunnelStartRefusal() == .cloudMachinesOff)
        #expect(await policy.resolvedTunnelStartRefusal() == .cloudMachinesOff)
    }

    @Test("the toggle alone is not enough: a machine count known to be zero refuses")
    func toggleWithoutMachine() async {
        let policy = policy(enabled: true, machine: false, configured: false)
        #expect(policy.allowsBackgroundCloudWork)
        #expect(policy.allowsLaunchTimeTunnelAdoption == false)
        #expect(policy.tunnelStartRefusal() == .noCloudMachine)
        #expect(await policy.resolvedTunnelStartRefusal() == .noCloudMachine)
    }

    @Test("the toggle plus a machine admits the tunnel")
    func toggleWithMachine() async {
        let policy = policy(enabled: true, usedCloud: true, machine: true, configured: false)
        #expect(policy.tunnelStartRefusal() == nil)
        #expect(await policy.resolvedTunnelStartRefusal() == nil)
        #expect(policy.allowsBackgroundCloudWork)
    }

    @Test("an explicit start settles the machine count against the control plane whatever the marker says; launch-time decisions never do")
    func unknownMachineCountIsResolvedOnDemand() async {
        let hasMachines = policy(enabled: true, machine: nil, configured: false, resolved: true)
        #expect(hasMachines.allowsBackgroundCloudWork)
        #expect(hasMachines.tunnelStartRefusal() == nil)
        #expect(await hasMachines.resolvedTunnelStartRefusal() == nil)

        let noMachines = policy(enabled: true, machine: nil, configured: false, resolved: false)
        #expect(noMachines.tunnelStartRefusal() == nil)
        #expect(await noMachines.resolvedTunnelStartRefusal() == .noCloudMachine)

        // Signed out or offline: no answer, no refusal; enrollment reports why.
        let unanswered = policy(enabled: true, machine: nil, configured: false, resolved: nil)
        #expect(await unanswered.resolvedTunnelStartRefusal() == nil)

        // A count last seen as zero is re-asked: a machine created elsewhere
        // admits the start; an unanswerable ask keeps the known refusal.
        let created = policy(enabled: true, machine: false, configured: false, resolved: true)
        #expect(created.tunnelStartRefusal() == .noCloudMachine)
        #expect(await created.resolvedTunnelStartRefusal() == nil)
        let stillNone = policy(enabled: true, machine: false, configured: false, resolved: nil)
        #expect(await stillNone.resolvedTunnelStartRefusal() == .noCloudMachine)

        // A marker that knows a machine is re-asked too: the last machine may
        // have been deleted outside this app since the last poll.
        let deletedElsewhere = policy(enabled: true, usedCloud: true, machine: true, configured: false, resolved: false)
        #expect(deletedElsewhere.tunnelStartRefusal() == nil)
        #expect(await deletedElsewhere.resolvedTunnelStartRefusal() == .noCloudMachine)
        // Offline with a marker that knows a machine: the local answer stands.
        let offlineKnown = policy(enabled: true, usedCloud: true, machine: true, configured: false, resolved: nil)
        #expect(await offlineKnown.resolvedTunnelStartRefusal() == nil)

        // The toggle still wins before anything is asked.
        let off = policy(enabled: false, machine: nil, configured: false, resolved: true)
        #expect(off.allowsBackgroundCloudWork == false)
        #expect(await off.resolvedTunnelStartRefusal() == .cloudMachinesOff)
    }

    @Test("prior Cloud use keeps the fleet alive and lets an inherited tunnel be adopted, but a start still needs the toggle")
    func priorUseWithoutToggle() async {
        let policy = policy(enabled: false, usedCloud: true, machine: nil, configured: true, resolved: true)
        #expect(policy.allowsBackgroundCloudWork)
        #expect(policy.allowsLaunchTimeTunnelAdoption)
        #expect(policy.tunnelStartRefusal() == .cloudMachinesOff)
        #expect(await policy.resolvedTunnelStartRefusal() == .cloudMachinesOff)
    }

    @Test("prior use is not a machine: with the toggle on, the tunnel still asks the control plane")
    func priorUseIsNotAMachine() async {
        let noneLeft = policy(enabled: true, usedCloud: true, machine: nil, configured: true, resolved: false)
        #expect(noneLeft.allowsBackgroundCloudWork)
        #expect(noneLeft.tunnelStartRefusal() == nil)
        #expect(await noneLeft.resolvedTunnelStartRefusal() == .noCloudMachine)
    }

    @Test("refusals map to user-presentable errors and stable wire tokens")
    func refusalTokens() {
        #expect(CloudTunnelStartRefusal.cloudMachinesOff.rawValue == "cloud-machines-off")
        #expect(CloudTunnelStartRefusal.noCloudMachine.rawValue == "no-cloud-machine")
        #expect(CloudTunnelStartRefusal.cloudMachinesOff.error == .cloudMachinesOff)
        #expect(CloudTunnelStartRefusal.noCloudMachine.error == .noCloudMachine)
        #expect(!CloudTunnelError.cloudMachinesOff.description.isEmpty)
        #expect(!CloudTunnelError.noCloudMachine.description.isEmpty)
        #expect(CloudTunnelError.cloudMachinesOff.description != CloudTunnelError.noCloudMachine.description)
    }

    // MARK: - The live inputs: defaults, the machine cache, and the tunnel files

    private struct LiveHarness {
        let suiteName: String
        let defaults: UserDefaults
        let home: URL
        let cache: CloudMachineCache
        let browser: VMTunnelManager
        let terminal: VMTunnelManager
        let policy: CloudActivationPolicy

        init() throws {
            suiteName = "cmux.cloud.activation.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-activation-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            cache = CloudMachineCache(defaults: defaults)
            browser = VMTunnelManager(
                home: home,
                interfaceName: "cmux-t",
                purpose: .browser,
                bundleIdentifier: "com.cmuxterm.app.tests"
            )
            terminal = VMTunnelManager(
                home: home,
                interfaceName: "cmux-t",
                purpose: .terminal,
                bundleIdentifier: "com.cmuxterm.app.tests"
            )
            policy = CloudActivationPolicy.live(
                defaults: defaults,
                machineCache: cache,
                browserTunnel: browser,
                terminalTunnel: terminal,
                resolveCloudMachine: { nil }
            )
        }

        func tearDown() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: home)
        }

        func turnCloudMachines(on enabled: Bool) {
            defaults.set(enabled, forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
        }

        /// What a previous opted-in session leaves behind: the browser-role config.
        func saveBrowserConfig() throws {
            let url = browser.configURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "[Interface]\nPrivateKey = test\n".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @Test("live inputs: a fresh install answers no to everything, the toggle and a listed machine open the gate, sign-out closes it")
    func liveInputsFollowDefaultsAndFiles() throws {
        let harness = try LiveHarness()
        defer { harness.tearDown() }
        let policy = harness.policy

        #expect(policy.allowsBackgroundCloudWork == false)
        #expect(policy.allowsLaunchTimeTunnelAdoption == false)
        #expect(policy.tunnelStartRefusal() == .cloudMachinesOff)

        harness.turnCloudMachines(on: true)
        #expect(policy.allowsBackgroundCloudWork)
        // Nothing has listed the fleet yet: unknown, so not a known refusal.
        #expect(policy.hasUsedCloud() == false)
        #expect(policy.hasCloudMachine() == nil)
        #expect(policy.tunnelStartRefusal() == nil)

        // The machine list came back empty, then a machine was created.
        harness.cache.record(hasAnyMachine: false)
        #expect(policy.hasUsedCloud() == false)
        #expect(policy.tunnelStartRefusal() == .noCloudMachine)
        harness.cache.record(hasAnyMachine: true)
        #expect(policy.hasUsedCloud())
        #expect(policy.tunnelStartRefusal() == nil)
        #expect(policy.allowsLaunchTimeTunnelAdoption == false)

        // A delete resets the marker to unknown (VMClient.destroy clears it):
        // still "used Cloud", but a start must ask again.
        harness.cache.clear()
        #expect(harness.cache.hasAnyMachine == nil)
        #expect(policy.hasCloudMachine() == nil)
        #expect(policy.tunnelStartRefusal() == nil)

        // Sign-out clears the cache too: the next account starts from unknown,
        // and unknown never opens background work on its own.
        harness.turnCloudMachines(on: false)
        #expect(policy.hasUsedCloud() == false)
        #expect(policy.allowsBackgroundCloudWork == false)
        harness.turnCloudMachines(on: true)

        harness.turnCloudMachines(on: false)
        #expect(policy.allowsBackgroundCloudWork == false)
        #expect(policy.tunnelStartRefusal() == .cloudMachinesOff)
    }

    @Test("live inputs: this Mac's own enrollment counts as having a machine; a saved VPN configuration allows launch-time adoption")
    func liveInputsHonorEnrollmentFiles() throws {
        let harness = try LiveHarness()
        defer { harness.tearDown() }
        let policy = harness.policy
        harness.turnCloudMachines(on: true)
        harness.cache.record(hasAnyMachine: false)
        #expect(policy.tunnelStartRefusal() == .noCloudMachine)
        harness.cache.clear()
        #expect(policy.hasCloudMachine() == nil)

        // The user-space hub enrolled the terminal role (a link to a machine):
        // this Mac used Cloud, so its fleet keeps polling even with the toggle
        // off, but it says nothing about the account's machines right now.
        _ = try harness.terminal.deviceFingerprint()
        #expect(policy.hasUsedCloud())
        #expect(policy.hasCloudMachine() == nil)
        #expect(policy.tunnelStartRefusal() == nil)
        #expect(policy.allowsBackgroundCloudWork)
        harness.turnCloudMachines(on: false)
        #expect(policy.allowsBackgroundCloudWork)
        harness.turnCloudMachines(on: true)
        #expect(policy.allowsLaunchTimeTunnelAdoption == false)
        harness.terminal.removeLocalCredentials()
        #expect(policy.hasUsedCloud() == false)
        #expect(policy.hasCloudMachine() == nil)

        // A previous session saved the browser-role config.
        try harness.saveBrowserConfig()
        #expect(policy.allowsLaunchTimeTunnelAdoption)
        #expect(policy.hasUsedCloud())
        #expect(policy.tunnelStartRefusal() == nil)
        harness.turnCloudMachines(on: false)
        // Adoption (cleanup) stays possible; a new start does not.
        #expect(policy.allowsLaunchTimeTunnelAdoption)
        #expect(policy.allowsBackgroundCloudWork)
        #expect(policy.tunnelStartRefusal() == .cloudMachinesOff)
        harness.browser.removeLocalCredentials()
        #expect(policy.allowsLaunchTimeTunnelAdoption == false)
    }

    @Test("the machine cache is unknown until the first list and forgets on clear")
    func machineCacheLifecycle() throws {
        let suiteName = "cmux.cloud.machineCache.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = CloudMachineCache(defaults: defaults)
        #expect(cache.hasAnyMachine == nil)
        cache.record(hasAnyMachine: true)
        #expect(cache.hasAnyMachine == true)
        cache.record(hasAnyMachine: false)
        #expect(cache.hasAnyMachine == false)
        cache.clear()
        #expect(cache.hasAnyMachine == nil)
    }

    @Test("Cloud Machines is off by default, on only through the Beta Features toggle, and never on under a managed DisableCloud")
    func cloudMachinesGateIsTheBetaToggle() throws {
        let suiteName = "cmux.cloud.feature.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let unmanaged = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, _ in nil })
        let managedOff = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, key in
            key == ManagedDevicePolicyKey.disableCloud.rawValue ? true : nil
        })

        #expect(CloudMachinesFeature.localOptIn(defaults: defaults) == false)
        #expect(CloudMachinesFeature.isEnabled(defaults: defaults, policy: unmanaged) == false)

        defaults.set(true, forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
        #expect(CloudMachinesFeature.isEnabled(defaults: defaults, policy: unmanaged))
        #expect(CloudMachinesFeature.isEnabled(defaults: defaults, policy: managedOff) == false)

        defaults.set(false, forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
        #expect(CloudMachinesFeature.isEnabled(defaults: defaults, policy: unmanaged) == false)
    }
}
