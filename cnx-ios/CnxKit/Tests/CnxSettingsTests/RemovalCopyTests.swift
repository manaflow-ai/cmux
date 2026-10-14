import Testing
@testable import CnxSettings

/// The remove-Mac confirmation: an online Mac whose host keeps itself off after a removal
/// (`removal-v1`) gets the "stays off" copy; an older or unknown Mac the truthful old one.
@MainActor @Suite struct RemovalCopyTests {
    static func mac(online: Bool) -> SettingsDevice {
        SettingsDevice(ids: ["m1"], kind: .mac, name: "Studio", online: online, lastSeenAt: nil, isThisDevice: false, receivesNotifications: false)
    }

    @Test func anOnlineMacThatHonorsRemovalStaysOff() {
        let text = PairedMacsPage.removalExplanation(Self.mac(online: true), connected: true, honorsRemoval: true)
        #expect(text.contains("It's online, so it will disconnect now. It stays off until you choose Allow Again in Settings → Mobile on that Mac."))
        #expect(!text.contains("add it back"))
    }

    @Test func anOlderOrUnknownMacCanAddItselfBack() {
        let text = PairedMacsPage.removalExplanation(Self.mac(online: true), connected: false)
        #expect(text.contains("cmux on that Mac can add it back"))
        #expect(!text.contains("Allow Again"))
    }

    @Test func anOfflineMacGetsTheOfflineCopyEitherWay() {
        for honors in [true, false] {
            let text = PairedMacsPage.removalExplanation(Self.mac(online: false), connected: false, honorsRemoval: honors)
            #expect(text.contains("To use it again"))
        }
    }
}
