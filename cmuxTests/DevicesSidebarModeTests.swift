import CmuxCloud
import CmuxSettings
import CmuxSurfaceCatalogModel
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

    @Test("Cloud off prevents discovery and hosting even with both preferences on")
    func cloudOffDisablesDevices() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
        defaults.set(true, forKey: DevicesCatalogSection().discoveryEnabled.userDefaultsKey)
        defaults.set(true, forKey: DevicesCatalogSection().incomingAccessEnabled.userDefaultsKey)
        #expect(!DevicesFeature.isDiscoveryEnabled(defaults: defaults))
        #expect(!MobileRemoteControlPolicy.allowsIncomingAccess(defaults: defaults))
        #expect(!RightSidebarMode.availableModes(defaults: defaults).contains(.machines))
    }

    @Test("Enabling Cloud alone does not opt a fresh install into Mac discovery or hosting")
    func freshInstallDoesNotStartDeviceNetworking() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
        #expect(!DevicesFeature.isDiscoveryEnabled(defaults: defaults, cloudEnabled: true))
        #expect(!MobileRemoteControlPolicy.allowsIncomingAccess(defaults: defaults, cloudEnabled: true))
        #expect(!MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: .dev))
    }

    @Test("The two device preferences remain independent within Cloud")
    func independentPreferencesWithinCloud() {
        let defaults = makeDefaults()
        let keys = DevicesCatalogSection()
        defaults.set(true, forKey: keys.discoveryEnabled.userDefaultsKey)
        defaults.set(false, forKey: keys.incomingAccessEnabled.userDefaultsKey)
        #expect(DevicesFeature.isDiscoveryEnabled(defaults: defaults, cloudEnabled: true))
        #expect(!MobileRemoteControlPolicy.allowsIncomingAccess(defaults: defaults, cloudEnabled: true))
        defaults.set(false, forKey: keys.discoveryEnabled.userDefaultsKey)
        defaults.set(true, forKey: keys.incomingAccessEnabled.userDefaultsKey)
        #expect(!DevicesFeature.isDiscoveryEnabled(defaults: defaults, cloudEnabled: true))
        #expect(MobileRemoteControlPolicy.allowsIncomingAccess(defaults: defaults, cloudEnabled: true))
    }

    @Test("A remote Cloud disable wins over saved device preferences")
    func remoteCloudGateDisablesDevices() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
        defaults.set(true, forKey: DevicesCatalogSection().discoveryEnabled.userDefaultsKey)
        defaults.set(true, forKey: DevicesCatalogSection().incomingAccessEnabled.userDefaultsKey)
        let policy = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil) { _, _ in nil }
        let enabled = CloudMachinesFeature.isEnabled(defaults: defaults, policy: policy, remoteEnabled: false)
        #expect(!DevicesFeature.isEnabled(defaults: defaults, policy: policy, cloudEnabled: enabled))
        #expect(!MobileRemoteControlPolicy.allowsIncomingAccess(defaults: defaults, cloudEnabled: enabled))
    }

    @Test("Device aliases open the same Cloud sidebar")
    func cliArgument() {
        #expect(RightSidebarMode.from(cliArgument: "devices") == .machines)
        #expect(RightSidebarMode.from(cliArgument: "device") == .machines)
        #expect(RightSidebarMode.from(cliArgument: "macs") == .machines)
        #expect(RightSidebarMode.from(cliArgument: "machines") == .machines, "the Cloud spelling is untouched")
        #expect(RightSidebarMode.machines.rawValue == "machines")
        #expect(RightSidebarMode.machines.shortcutAction == .switchRightSidebarToMachines)
        // The Cloud tool opens as a pane since 2f8f5af7a0c; the aliases must not change that.
        #expect(RightSidebarMode.machines.canOpenAsPane)
    }

    @Test("Cloud availability gates both machine sources")
    func availability() {
        #expect(RightSidebarMode.machines.isAvailable(feedEnabled: true, dockEnabled: true, machinesEnabled: true, devicesEnabled: false))
        #expect(!RightSidebarMode.machines.isAvailable(feedEnabled: false, dockEnabled: false, machinesEnabled: false, devicesEnabled: true))
        #expect(RightSidebarMode.machines.isAvailable(feedEnabled: false, dockEnabled: false, machinesEnabled: false) == false, "callers that predate Devices see it hidden")
        #expect(
            RightSidebarMode.availableModes(feedEnabled: false, dockEnabled: false, machinesEnabled: true, devicesEnabled: true)
                == [.files, .find, .sessions, .machines]
        )
        #expect(
            RightSidebarMode.availableModes(feedEnabled: true, dockEnabled: true, machinesEnabled: false, devicesEnabled: true)
                == [.files, .find, .sessions, .feed, .dock]
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
        #expect(!DevicesFeature.isEnabled(defaults: defaults, policy: banned, cloudEnabled: true))
        let permissive = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil) { _, _ in nil }
        #expect(DevicesFeature.isEnabled(defaults: defaults, policy: permissive, cloudEnabled: true))
    }

    @Test("Hosting remains opt-in and separate from discovery")
    func hostListenerGate() {
        let defaults = makeDefaults()
        let keys = DevicesCatalogSection()
        #expect(!MobileRemoteControlPolicy.allowsIncomingAccess(defaults: defaults, cloudEnabled: true))
        defaults.set(false, forKey: keys.discoveryEnabled.userDefaultsKey)
        defaults.set(true, forKey: keys.incomingAccessEnabled.userDefaultsKey)
        #expect(MobileRemoteControlPolicy.allowsIncomingAccess(defaults: defaults, cloudEnabled: true))
        defaults.set(false, forKey: keys.incomingAccessEnabled.userDefaultsKey)
        #expect(!MobileRemoteControlPolicy.allowsIncomingAccess(defaults: defaults, cloudEnabled: true))
    }
}
