public import CmuxiOSFeatureKit
import Foundation

/// The device registry onboarding uses while the devices seam is on its
/// mock (until lane B6): only this phone at first, then a same-account Mac
/// is discovered after a short wait on the injected clock, so the pair step
/// shows searching, found, connecting and connected.
public enum OnboardingDemoDevices {
    public static let discoveryDelay: Duration = .milliseconds(2500)

    @MainActor
    public static func make(clock: any Clock<Duration>) -> MockDeviceRegistry {
        let registry = MockDeviceRegistry(devices: [
            DeviceRecord(id: "dev-phone", name: "iPhone", platform: .iPhone, trust: .trusted, isThisDevice: true, lastSeen: Date()),
        ])
        let hub = registry.hub
        Task {
            try? await clock.sleep(for: discoveryDelay)
            _ = try? await hub.commit { devices in
                devices.append(DeviceRecord(id: "dev-laptop", name: "MacBook Pro", platform: .mac, trust: .discovered))
            }
        }
        return registry
    }
}
