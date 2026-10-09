import CmuxiOSFeatureKit
import CmuxiOSSettingsCore
import CmuxiOSShell
import Testing

@MainActor
@Suite struct ShellSettingsModelTests {
    private func model(account: (any AccountControlling)? = nil, links: (any LinkDiagnosticsSource)? = nil,
                       signOut: @escaping @MainActor () async -> Void = {}) -> ShellSettingsModel {
        ShellSettingsModel(
            account: ShellAccount(displayName: "Cached", email: nil),
            about: ShellAbout(version: "1.0", build: "1", devTag: nil),
            registry: MockDeviceRegistry(), developer: nil,
            accountController: account, linkDiagnostics: links, signOut: signOut
        )
    }

    @Test func optionalSectionsStayHiddenWithoutTheirOwners() {
        let settings = model()
        #expect(settings.accountModel == nil)
        #expect(settings.terminal == nil && settings.notifications == nil && settings.privacy == nil)
        #expect(settings.profile.displayName == "Cached")
    }

    @Test func profilePrefersTheLiveAccount() {
        let settings = model(account: MockAccountController())
        #expect(settings.profile.displayName == "Ada Lovelace")
        #expect(settings.profile.email == "ada@example.com")
    }

    @Test func observeMirrorsDevicesAndBadges() async {
        let settings = model(links: MockLinkDiagnosticsSource())
        let task = Task { await settings.observe() }
        defer { task.cancel() }
        while settings.devicesModel?.devices.isEmpty != false || settings.devicesModel?.badges.isEmpty != false { await Task.yield() }
        #expect(settings.devicesModel?.sections.map(\.kind) == [.thisDevice, .macs])
        #expect(settings.devicesModel?.badge(for: MockFixtures.studio.rawValue) != nil)
    }

    @Test func signOutRunsOnceAtATime() async {
        var calls = 0
        let settings = model { calls += 1 }
        await settings.signOut()
        #expect(calls == 1)
        #expect(!settings.isSigningOut)
    }
}
