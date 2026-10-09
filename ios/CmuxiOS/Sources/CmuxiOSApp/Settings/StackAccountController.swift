import CmuxAuthRuntime
import CmuxiOSAuth
import CmuxiOSSettingsCore
import Foundation
import Observation

/// The Account section's owner adapter over the kept Stack sign-in
/// (`AuthCoordinator`): profile, teams and selection observed with
/// `withObservationTracking` (no polling), team switch and account deletion
/// through the coordinator's own actions, sign-out through `StackAuthGate`
/// so install revocation runs first.
@MainActor
final class StackAccountController: AccountControlling {
    private let gate: StackAuthGate
    private var subscribers: [UUID: AsyncStream<AccountSnapshot>.Continuation] = [:]
    private var observing = false

    init(gate: StackAuthGate) {
        self.gate = gate
    }

    var snapshot: AccountSnapshot {
        let coordinator = gate.coordinator
        let user = coordinator.currentUser
        let email = user?.primaryEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = user?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AccountSnapshot(
            displayName: name?.isEmpty == false ? name! : (email ?? ""),
            email: email?.isEmpty == false ? email : nil,
            teams: coordinator.availableTeams.map { AccountTeam(id: $0.id, name: $0.displayName) },
            selectedTeamID: coordinator.resolvedTeamID,
            isChangingTeam: coordinator.isSelectingTeam
        )
    }

    func updates() -> AsyncStream<AccountSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AccountSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(snapshot)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[id] = nil }
        }
        if !observing { observe() }
        return stream
    }

    /// Re-arms after every change while anyone listens.
    private func observe() {
        guard !subscribers.isEmpty else {
            observing = false
            return
        }
        observing = true
        withObservationTracking {
            _ = snapshot
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let next = self.snapshot
                for continuation in self.subscribers.values { continuation.yield(next) }
                self.observe()
            }
        }
    }

    func selectTeam(_ id: AccountTeam.ID) async throws {
        try await gate.coordinator.selectTeam(id: id)
    }

    func deleteAccount() async -> Result<AccountDeletionOutcome, AccountDeletionFailure> {
        do {
            switch try await gate.coordinator.deleteAccount() {
            case .completed: return .success(.completed)
            case .completedWithIncompleteServerCleanup: return .success(.completedWithIncompleteServerCleanup)
            }
        } catch {
            return .failure(Self.failure(for: error))
        }
    }

    func signOut() async {
        await gate.signOut()
    }

    /// The shipping app's mapping (`DeleteAccountFailureKind.init(error:)`).
    static func failure(for error: any Error) -> AccountDeletionFailure {
        if let request = error as? AccountDeletionRequestError {
            switch request {
            case .unauthorized: return .unauthorized
            case .stackDeleteIncomplete: return .stackDeleteIncomplete
            case .timedOut: return .timedOut
            case .completionUnknown: return .unknown
            case .localTransportFailure: return .connection
            case .invalidAPIBaseURL, .rejected, .invalidResponse: return .generic
            }
        }
        if let auth = error as? AuthError {
            switch auth {
            case .unauthorized: return .unauthorized
            case .timedOut: return .timedOut
            default: return .generic
            }
        }
        return .generic
    }
}
