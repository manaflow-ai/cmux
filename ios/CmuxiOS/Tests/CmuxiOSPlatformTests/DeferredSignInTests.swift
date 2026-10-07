import CmuxiOSFeatureKit
import CmuxiOSPlatform
import Foundation
import Testing

@Suite("Deferred sign-in")
struct DeferredSignInTests {
    @Test func signedInAlwaysWins() {
        #expect(AccessLevel(isRestoring: false, isSignedIn: true, isGuest: true) == .account)
        #expect(AccessLevel(isRestoring: true, isSignedIn: false, isGuest: true) == .restoring)
        #expect(AccessLevel(isRestoring: false, isSignedIn: false, isGuest: true) == .guest)
        #expect(AccessLevel(isRestoring: false, isSignedIn: false, isGuest: false) == .signIn)
    }

    @Test func automatedSignInIgnoresAStoredGuestChoice() {
        let dogfood = GuestAccessPolicy(environment: ["CMUX_DOGFOOD_READINESS_NONCE": "n"], isDebug: true)
        #expect(!dogfood.isGuest(stored: true))
        let uiTest = GuestAccessPolicy(environment: ["CMUX_UITEST_STACK_EMAIL": "a@b.c", "CMUX_IOS_GUEST": "1"], isDebug: true)
        #expect(!uiTest.isGuest(stored: true))
    }

    @Test func debugCanForceGuestAndReleaseHonorsTheStoredChoice() {
        #expect(GuestAccessPolicy(environment: ["CMUX_IOS_GUEST": "1"], isDebug: true).isGuest(stored: false))
        let release = GuestAccessPolicy(environment: ["CMUX_IOS_GUEST": "1"], isDebug: false)
        #expect(!release.isGuest(stored: false))
        #expect(release.isGuest(stored: true))
    }

    @Test func guestModeStorePersists() {
        let name = "guest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = GuestModeStore(defaults: defaults)
        #expect(!store.isChosen)
        store.choose()
        #expect(GuestModeStore(defaults: defaults).isChosen)
        store.clear()
        #expect(!store.isChosen)
    }

    @Test @MainActor func guestShellOpensHostsAndParksAccountRoutesUntilSignIn() {
        let router = ShellRouter(parser: ShellRouteParser())
        var opened: [ShellRoute] = []
        var prompts: [ShellRoute] = []
        router.install { opened.append($0) }
        router.onNeedsAccount = { prompts.append($0) }
        router.setAccess(.guest)
        #expect(router.open(.hosts) == .handled)
        #expect(router.open(.settings) == .handled)
        #expect(router.open(.feed(item: nil)) == .deferred)
        #expect(prompts == [.feed(item: nil)])
        #expect(opened == [.hosts, .settings])
        router.setAccess(.account)
        #expect(opened == [.hosts, .settings, .feed(item: nil)])
    }

    @Test @MainActor func signingOutOfTheAccountDropsTheParkedRoute() {
        let router = ShellRouter(parser: ShellRouteParser())
        var opened: [ShellRoute] = []
        router.install { opened.append($0) }
        router.setAccess(.account)
        router.setAccess(.none)
        _ = router.open(.workspaces)
        router.setAccess(.guest)
        router.setAccess(.account)
        #expect(opened == [.workspaces])
        router.setAccess(.guest)
        #expect(router.pending == nil)
    }
}
