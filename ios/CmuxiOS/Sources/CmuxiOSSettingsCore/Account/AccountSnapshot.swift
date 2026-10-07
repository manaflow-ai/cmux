/// The signed-in account as Settings shows it.
public struct AccountSnapshot: Hashable, Sendable {
    public var displayName: String
    public var email: String?
    public var teams: [AccountTeam]
    public var selectedTeamID: AccountTeam.ID?
    /// A team switch is in flight at the owner.
    public var isChangingTeam: Bool

    public init(displayName: String, email: String?, teams: [AccountTeam] = [],
                selectedTeamID: AccountTeam.ID? = nil, isChangingTeam: Bool = false) {
        self.displayName = displayName
        self.email = email
        self.teams = teams
        self.selectedTeamID = selectedTeamID
        self.isChangingTeam = isChangingTeam
    }
}
