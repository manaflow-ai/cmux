import Foundation
import Testing
@testable import CnxModel

/// verify/persistence.md: account preferences are live for one account at a
/// time and come back when the same account signs in again.
@Suite struct AccountPreferencesTests {
    func defaults() -> UserDefaults { UserDefaults(suiteName: "cnx-prefs-\(UUID().uuidString)")! }

    @Test func anEarlierBuildsLivePreferencesBelongToTheAccountSignedInNow() {
        let d = defaults()
        d.set(true, forKey: "cnx.setupComplete")
        let prefs = AccountPreferences(defaults: d)
        prefs.activate(userID: "user-a")
        #expect(d.bool(forKey: "cnx.setupComplete"))
        #expect(prefs.currentUserID == "user-a")
    }

    @Test func anUnfinishedSignOutIsPutAwayWhenAnotherAccountSignsIn() {
        let d = defaults()
        let prefs = AccountPreferences(defaults: d)
        prefs.activate(userID: "user-a")
        d.set(true, forKey: "cnx.setupComplete")
        d.set(Data([1]), forKey: "cnx.lastOpenLocation")
        // No sign-out ran (the app was killed); another account signs in.
        prefs.activate(userID: "user-b")
        #expect(d.object(forKey: "cnx.setupComplete") == nil)
        #expect(d.object(forKey: "cnx.lastOpenLocation") == nil)
        prefs.stash(userID: "user-b")
        prefs.activate(userID: "user-a")
        #expect(d.bool(forKey: "cnx.setupComplete"))
        #expect(d.data(forKey: "cnx.lastOpenLocation") == Data([1]))
    }

    @Test func aSignedOutFirstLaunchAfterAnOlderBuildDropsItsPreferences() {
        let d = defaults()
        d.set(true, forKey: "cnx.setupComplete")
        let prefs = AccountPreferences(defaults: d)
        #expect(prefs.settleSignedOut())
        #expect(d.object(forKey: "cnx.setupComplete") == nil)
        #expect(!prefs.settleSignedOut())
        prefs.activate(userID: "user-b")
        #expect(d.object(forKey: "cnx.setupComplete") == nil)
    }

    @Test func aWriteAfterSignOutGoesToNobody() {
        let d = defaults()
        let prefs = AccountPreferences(defaults: d)
        prefs.activate(userID: "user-a")
        d.set(true, forKey: "cnx.setupComplete")
        prefs.stash(userID: "user-a")
        // A view saving while it fades out.
        d.set(Data([7]), forKey: "cnx.lastOpenLocation")
        prefs.activate(userID: "user-b")
        #expect(d.object(forKey: "cnx.lastOpenLocation") == nil)
        #expect(d.object(forKey: "cnx.setupComplete") == nil)
        // Read without activating: user-a's record.
        #expect(prefs.value("cnx.setupComplete", userID: "user-a") as? Bool == true)
    }

    @Test func deviceAndAuthKeysNeverMove() {
        #expect(!AccountPreferences.moves("cnx.settings.transport"))
        #expect(!AccountPreferences.moves("cnx.auth.selectedTeam"))
        #expect(!AccountPreferences.moves("cnx.dev.relayOnly"))
        #expect(AccountPreferences.moves("cnx.live.mac.team-1"))
        #expect(AccountPreferences.moves("cnx.setupComplete"))
    }
}
