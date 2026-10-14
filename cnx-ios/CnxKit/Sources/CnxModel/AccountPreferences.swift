import Foundation

/// The signed-in account's own preferences (`AppStore.isAccountPreference`:
/// setup done, the remembered Mac per team, last tab per workspace, recent
/// folders, Mac filters, team colors) plus where the app was last open.
///
/// While an account is signed in they live under their usual keys, where
/// every reader finds them. Sign-out moves them into that account's own
/// record (`cnx.account.<user id>`), so the next account starts clean and the
/// same account, signing in again, gets them back: no setup again, the same
/// Mac and workspace (verify/persistence.md). None of them is a secret: ids,
/// folder paths, colors and flags.
public final class AccountPreferences: @unchecked Sendable { // crash-allow: UserDefaults is thread-safe
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static let standard = AccountPreferences()

    /// The user whose preferences are under the live keys now.
    static let currentKey = "cnx.account.current"
    static func recordKey(_ userID: String) -> String { "cnx.account.\(userID)" }

    /// Keys that move with the account. The auth runtime owns
    /// `cnx.auth.selectedTeam` (it clears it on sign-out and the service
    /// restores it), so it stays out.
    public static func moves(_ key: String) -> Bool {
        guard key != "cnx.auth.selectedTeam" else { return false }
        return AppStore.isAccountPreference(key) || key == "cnx.lastOpenLocation"
    }

    private var liveKeys: [String] {
        defaults.dictionaryRepresentation().keys.filter(Self.moves)
    }

    /// The user whose preferences are live, if any.
    public var currentUserID: String? { defaults.string(forKey: Self.currentKey) }

    /// Sign-in (and every launch while signed in): makes `userID`'s preferences live.
    ///
    /// - Another account's live preferences (a sign-out that never finished)
    ///   are put away under that account first.
    /// - With no account recorded (a build before this, or a fresh install),
    ///   the live preferences already belong to the signed-in account: earlier
    ///   builds deleted them on every sign-out. They are kept as `userID`'s.
    public func activate(userID: String) {
        let current = currentUserID
        if current == userID { return }
        if let current { stash(userID: current) }
        if let record = defaults.dictionary(forKey: Self.recordKey(userID)) {
            for key in liveKeys { defaults.removeObject(forKey: key) }
            for (key, value) in record where Self.moves(key) { defaults.set(value, forKey: key) }
            defaults.removeObject(forKey: Self.recordKey(userID))
        } else if current != nil {
            // Another account's preferences were put away: this one starts clean.
            for key in liveKeys { defaults.removeObject(forKey: key) }
        }
        defaults.set(userID, forKey: Self.currentKey)
    }

    /// Sign-out: puts the live preferences away under `userID` (the account
    /// signing out) and clears the live keys.
    public func stash(userID: String) {
        var record: [String: Any] = [:]
        for key in liveKeys {
            if let value = defaults.object(forKey: key) { record[key] = value }
            defaults.removeObject(forKey: key)
        }
        if record.isEmpty {
            defaults.removeObject(forKey: Self.recordKey(userID))
        } else {
            defaults.set(record, forKey: Self.recordKey(userID))
        }
        if currentUserID == userID { defaults.removeObject(forKey: Self.currentKey) }
    }

    /// Account deletion: the account's record goes (live keys are cleared by sign-out).
    public func forget(userID: String) {
        defaults.removeObject(forKey: Self.recordKey(userID))
    }
}
