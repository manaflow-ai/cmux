import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// My Devices shares Cloud in every entry point: the mode enum,
/// its CLI spelling, the independent preferences, managed policy, and host listener.
@Suite("Devices: sidebar mode, gate, and host listener")
struct DevicesSidebarModeTests {
    private func makeDefaults() -> UserDefaults {
        let name = "DevicesSidebarModeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("The two device preferences work without a beta opt-in")
    func independentPreferencesWithoutBeta() {
        let defaults = makeDefaults()
        let keys = DevicesCatalogSection()
        defaults.set(false, forKey: "devices.beta.enabled")
        defaults.set(true, forKey: keys.discoveryEnabled.userDefaultsKey)
        defaults.set(false, forKey: keys.incomingAccessEnabled.userDefaultsKey)
        #expect(DevicesFeature.isDiscoveryEnabled(defaults: defaults))
        #expect(!MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: .stable))

        defaults.set(false, forKey: keys.discoveryEnabled.userDefaultsKey)
        defaults.set(true, forKey: keys.incomingAccessEnabled.userDefaultsKey)
        #expect(!DevicesFeature.isDiscoveryEnabled(defaults: defaults))
        #expect(MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: .stable))
    }

    @Test("My Devices remains reachable while discovery and Cloud Machines are off")
    func disabledDiscoveryKeepsItsControlsReachable() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
        defaults.set(false, forKey: "devices.beta.enabled")
        defaults.set(false, forKey: DevicesCatalogSection().discoveryEnabled.userDefaultsKey)
        #expect(RightSidebarMode.availableModes(defaults: defaults).contains(.machines))
    }

    @Test("Device aliases open the same Cloud sidebar")
    func cliArgument() {
        #expect(RightSidebarMode.from(cliArgument: "devices") == .machines)
        #expect(RightSidebarMode.from(cliArgument: "device") == .machines)
        #expect(RightSidebarMode.from(cliArgument: "macs") == .machines)
        #expect(RightSidebarMode.from(cliArgument: "machines") == .machines, "the Cloud spelling is untouched")
        #expect(RightSidebarMode.machines.rawValue == "machines")
        #expect(RightSidebarMode.machines.shortcutAction == .switchRightSidebarToMachines)
        #expect(!RightSidebarMode.machines.canOpenAsPane)
    }

    @Test("Cloud appears once when either machine source is enabled")
    func availability() {
        #expect(RightSidebarMode.machines.isAvailable(feedEnabled: true, dockEnabled: true, machinesEnabled: true, devicesEnabled: false))
        #expect(RightSidebarMode.machines.isAvailable(feedEnabled: false, dockEnabled: false, machinesEnabled: false, devicesEnabled: true))
        #expect(RightSidebarMode.machines.isAvailable(feedEnabled: false, dockEnabled: false, machinesEnabled: false) == false, "callers that predate Devices see it hidden")
        #expect(
            RightSidebarMode.availableModes(feedEnabled: false, dockEnabled: false, machinesEnabled: true, devicesEnabled: true)
                == [.files, .find, .sessions, .machines]
        )
        #expect(
            RightSidebarMode.availableModes(feedEnabled: true, dockEnabled: true, machinesEnabled: false, devicesEnabled: true)
                == [.files, .find, .sessions, .feed, .dock, .machines]
        )
        #expect(
            RightSidebarMode.availableModes(feedEnabled: false, dockEnabled: false, machinesEnabled: true)
                == [.files, .find, .sessions, .machines]
        )
    }

    @Test("Reveal requests stay scoped to their target window")
    @MainActor
    func revealRequestsAreWindowScoped() {
        let registry = DeviceSurfaceProviderRegistry()
        let first = UUID()
        let second = UUID()
        let instance = SurfaceDeviceInstanceID(deviceID: "mac-a", tag: "default")
        registry.reveal(instance: instance, windowID: first)
        #expect(registry.takePendingReveal(windowID: second) == nil)
        #expect(registry.takePendingReveal(windowID: first) == instance)
    }

    @Test("Managed discovery policy overrides the discovery preference")
    func featureGate() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: DevicesCatalogSection().discoveryEnabled.userDefaultsKey)
        let banned = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil) { _, key -> Any? in
            key == ManagedDevicePolicyKey.disableRemoteControl.rawValue ? (true as Any) : nil
        }
        #expect(!DevicesFeature.isEnabled(defaults: defaults, policy: banned))
        let permissive = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil) { _, _ in nil }
        #expect(DevicesFeature.isEnabled(defaults: defaults, policy: permissive))
    }

    @Test("Discoverability controls the host independently of outgoing discovery")
    func hostListenerGate() {
        let defaults = makeDefaults()
        let keys = DevicesCatalogSection()
        defaults.set(false, forKey: keys.discoveryEnabled.userDefaultsKey)
        defaults.set(true, forKey: keys.incomingAccessEnabled.userDefaultsKey)
        #expect(MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: .stable))
        #expect(MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: .dev))
        defaults.set(false, forKey: MobileHostService.listeningEnabledDefaultsKey)
        #expect(MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: .stable))
        defaults.set(false, forKey: keys.incomingAccessEnabled.userDefaultsKey)
        #expect(!MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: .stable))
        #expect(!MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: .dev))
    }
}
