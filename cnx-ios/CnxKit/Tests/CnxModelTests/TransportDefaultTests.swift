import Foundation
import Testing
@testable import CnxModel

/// verify/hybrid-link.md: WireGuard is the default transport (browser video
/// rides a WebRTC media session beside it); a saved choice stays.
@MainActor
@Suite struct TransportDefaultTests {
    private func defaults() -> UserDefaults {
        let name = "transport-default-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func anInstallWithNoSavedChoiceGetsWireGuard() {
        #expect(SettingsStore(defaults: defaults()).transport == .wireguard)
    }

    @Test func aSavedWebRTCChoiceStays() {
        let defaults = defaults()
        defaults.set("webrtc", forKey: "cnx.settings.transport")
        #expect(SettingsStore(defaults: defaults).transport == .webrtc)
        defaults.set("wireguard", forKey: "cnx.settings.transport")
        #expect(SettingsStore(defaults: defaults).transport == .wireguard)
    }

    @Test func choosingSavesIt() {
        let defaults = defaults()
        let store = SettingsStore(defaults: defaults)
        store.transport = .webrtc
        #expect(defaults.string(forKey: "cnx.settings.transport") == "webrtc")
        #expect(SettingsStore(defaults: defaults).transport == .webrtc)
    }

    @Test func thePickerListsWireGuardFirstAsRecommended() {
        #expect(TransportKind.allCases == [.wireguard, .webrtc])
        #expect(TransportKind.wireguard.pickerTitle == "WireGuard (recommended)")
        #expect(TransportKind.webrtc.pickerTitle == "WebRTC only")
        #expect(TransportKind.webrtc.title == "WebRTC only")
    }
}
