import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// My Devices has its own beta-gated right-sidebar mode: the mode enum,
/// its CLI spelling, the Beta gate (with the managed remote-control ban on
/// top), and the mobile host listener that publishes this Mac while it is on.
@Suite("Devices: sidebar mode, gate, and host listener")
struct DevicesSidebarModeTests {
    private func makeDefaults() -> UserDefaults {
        let name = "DevicesSidebarModeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Device aliases open the My Devices sidebar")
    func cliArgument() {
        #expect(RightSidebarMode.from(cliArgument: "devices") == .devices)
        #expect(RightSidebarMode.from(cliArgument: "device") == .devices)
        #expect(RightSidebarMode.from(cliArgument: "macs") == .devices)
        #expect(RightSidebarMode.from(cliArgument: "machines") == .machines, "the Cloud spelling is untouched")
        #expect(RightSidebarMode.machines.rawValue == "machines")
        #expect(RightSidebarMode.machines.shortcutAction == .switchRightSidebarToMachines)
        #expect(!RightSidebarMode.machines.canOpenAsPane)
    }

    @Test("Cloud and My Devices appear independently behind their beta gates")
    func availability() {
        #expect(RightSidebarMode.machines.isAvailable(feedEnabled: true, dockEnabled: true, machinesEnabled: true, devicesEnabled: false))
        #expect(RightSidebarMode.devices.isAvailable(feedEnabled: false, dockEnabled: false, machinesEnabled: false, devicesEnabled: true))
        #expect(RightSidebarMode.machines.isAvailable(feedEnabled: false, dockEnabled: false, machinesEnabled: false, devicesEnabled: true) == false)
        #expect(RightSidebarMode.devices.isAvailable(feedEnabled: false, dockEnabled: false, machinesEnabled: false) == false, "callers that predate Devices see it hidden")
        #expect(
            RightSidebarMode.availableModes(feedEnabled: false, dockEnabled: false, machinesEnabled: true, devicesEnabled: true)
                == [.files, .find, .sessions, .machines, .devices]
        )
        #expect(
            RightSidebarMode.availableModes(feedEnabled: true, dockEnabled: true, machinesEnabled: false, devicesEnabled: true)
                == [.files, .find, .sessions, .feed, .dock, .devices]
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

    @Test("The Beta setting is off by default, and a managed remote-control ban wins over it")
    func featureGate() {
        let defaults = makeDefaults()
        #expect(DevicesFeature.isEnabled(defaults: defaults) == false)
        #expect(DevicesFeature.localOptIn(defaults: defaults) == false)
        #expect(RightSidebarBetaFeatureSettings.isDevicesEnabled(defaults: defaults) == false)
        #expect(!RightSidebarMode.availableModes(defaults: defaults).contains(.devices))

        defaults.set(true, forKey: RightSidebarBetaFeatureSettings.devicesEnabledKey)
        #expect(DevicesFeature.localOptIn(defaults: defaults))
        #expect(DevicesFeature.isEnabled(defaults: defaults))
        #expect(RightSidebarBetaFeatureSettings.isDevicesEnabled(defaults: defaults))
        #expect(RightSidebarMode.availableModes(defaults: defaults).contains(.devices))
        #expect(RightSidebarMode.devices.isAvailable(defaults: defaults))

        let banned = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil) { _, key -> Any? in
            key == ManagedDevicePolicyKey.disableRemoteControl.rawValue ? (true as Any) : nil
        }
        #expect(DevicesFeature.isEnabled(defaults: defaults, policy: banned) == false)
        let permissive = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil) { _, _ in nil }
        #expect(DevicesFeature.isEnabled(defaults: defaults, policy: permissive))
        #expect(BetaFeaturesCatalogSection().devices.userDefaultsKey == RightSidebarBetaFeatureSettings.devicesEnabledKey)
        #expect(BetaFeaturesCatalogSection().devices.defaultValue == false)
    }

    @Test("The mobile host listens while Devices is on, even with iOS pairing off, unless policy bans it")
    func hostListenerGate() {
        let defaults = makeDefaults()
        #expect(MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: .stable) == false)
        #expect(MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: .dev))
        defaults.set(false, forKey: MobileHostService.listeningEnabledDefaultsKey)
        #expect(MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: .dev) == false)

        defaults.set(true, forKey: RightSidebarBetaFeatureSettings.devicesEnabledKey)
        #expect(MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: .stable), "publishing this Mac to the account needs the listener")
        #expect(MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: .dev))
        #expect(
            MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: .stable, devicesPublishing: false) == false,
            "a managed ban falls back to the pairing overrides"
        )
        defaults.removeObject(forKey: MobileHostService.listeningEnabledDefaultsKey)
        #expect(MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: .dev, devicesPublishing: false))
    }
}
