public import Observation

/// The Account section: profile, team switcher, Delete Account and its
/// failure alert. Successful deletion signs out through the normal owner.
@MainActor
@Observable
public final class AccountSettingsModel {
    public private(set) var snapshot: AccountSnapshot
    public private(set) var isDeleting = false
    /// The last team switch failed; the picker shows the owner's value.
    public private(set) var teamChangeFailed = false
    /// Shown as an alert; `acknowledgeDeletionAlert()` dismisses it.
    public private(set) var deletionAlert: AccountDeletionFailure?
    @ObservationIgnored private let controller: any AccountControlling

    public init(controller: any AccountControlling) {
        self.controller = controller
        snapshot = controller.snapshot
    }

    public var selectedTeam: AccountTeam? {
        snapshot.teams.first { $0.id == snapshot.selectedTeamID }
    }

    /// Mirrors the account until the calling task is cancelled.
    public func observe() async {
        for await next in controller.updates() {
            snapshot = next
        }
    }

    public func selectTeam(_ id: AccountTeam.ID) async {
        guard id != snapshot.selectedTeamID, !snapshot.isChangingTeam else { return }
        teamChangeFailed = false
        do {
            try await controller.selectTeam(id)
        } catch {
            teamChangeFailed = true
        }
        snapshot = controller.snapshot
    }

    public func deleteAccount() async {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        switch await controller.deleteAccount() {
        case .success(.completed):
            await controller.signOut()
        case .success(.completedWithIncompleteServerCleanup):
            deletionAlert = .serverCleanupIncomplete
        case .failure(let failure):
            deletionAlert = failure
        }
    }

    /// Dismisses the alert; signs out when the account is gone.
    public func acknowledgeDeletionAlert() async {
        guard let alert = deletionAlert else { return }
        deletionAlert = nil
        if alert.signsOutAfterAcknowledgement { await controller.signOut() }
    }
}
