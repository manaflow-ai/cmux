import CmuxiOSFeatureKit
@testable import CmuxiOSOnboardingCore
import Testing

@Suite("Keep-awake card")
struct KeepAwakeCardTests {
    @Test("The card follows pairing when the app offers it, and is skippable")
    func stepOrderAndSkip() {
        let offered = OnboardingContext(isSignedIn: true, hasTrustedMac: false, offersKeepAwake: true)
        var flow = OnboardingFlow(progress: OnboardingProgress(current: .pair), context: offered)
        flow.send(.advance)
        #expect(flow.current == .keepAwake)
        #expect(flow.canSkipStep)
        flow.send(.skipStep)
        #expect(flow.progress.outcomes[.keepAwake] == .skipped)
        #expect(flow.current == .sshHost)
    }

    @Test("Without the offer, a replay, or signed out, the card never shows")
    func notApplicable() {
        #expect(!OnboardingFlow(context: OnboardingContext(isSignedIn: true)).applies(.keepAwake))
        #expect(!OnboardingFlow(context: OnboardingContext(isSignedIn: true, mode: .replay, offersKeepAwake: true)).applies(.keepAwake))
        #expect(!OnboardingFlow(context: OnboardingContext(isSignedIn: false, offersKeepAwake: true)).applies(.keepAwake))
        #expect(OnboardingFlow(context: OnboardingContext(isSignedIn: true, offersKeepAwake: true)).applies(.keepAwake))
    }

    @Test("Rows are trusted Macs by name, joined with their reports")
    func projection() {
        let devices = [
            DeviceRecord(id: "d1", name: "Studio", platform: .mac, trust: .trusted, hostID: "h1"),
            DeviceRecord(id: "d2", name: "Air", platform: .mac, trust: .trusted, hostID: "h2"),
            DeviceRecord(id: "d3", name: "mini", platform: .mac, trust: .trusted, hostID: "h3"),
            DeviceRecord(id: "d4", name: "Old", platform: .mac, trust: .revoked, hostID: "h4"),
            DeviceRecord(id: "d5", name: "Found", platform: .mac, trust: .discovered, hostID: "h5"),
            DeviceRecord(id: "d6", name: "Phone", platform: .iPhone, trust: .trusted, isThisDevice: true),
            DeviceRecord(id: "d7", name: "No host", platform: .mac, trust: .trusted),
        ]
        let reports: [HostID: KeepAwakeReport] = [
            HostID("h1"): KeepAwakeReport(isSupported: true, isEnabled: true),
            HostID("h2"): KeepAwakeReport(isSupported: false, isEnabled: nil),
        ]
        let card = KeepAwakeCardProjection(devices: devices, reports: reports)
        #expect(card.macs == [
            KeepAwakeCardMac(id: HostID("h2"), name: "Air", availability: .unavailable),
            KeepAwakeCardMac(id: HostID("h3"), name: "mini", availability: .checking),
            KeepAwakeCardMac(id: HostID("h1"), name: "Studio", availability: .available(isOn: true)),
        ])
        #expect(card.hasAvailableMac)
        #expect(!KeepAwakeCardProjection(devices: devices, reports: [:]).hasAvailableMac)
    }
}
