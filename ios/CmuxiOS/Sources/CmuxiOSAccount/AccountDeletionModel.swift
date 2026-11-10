import Observation

/// Settings > Delete Account (App Store Guideline 5.1.1(v)): ask, delete,
/// show progress, explain a failure with a retry, sign out on success.
/// The request and the sign-out are injected, so the flow is tested
/// without a network or a session.
@MainActor
@Observable
public final class AccountDeletionModel {
    public private(set) var phase: AccountDeletionPhase

    @ObservationIgnored private let delete: @MainActor () async throws -> Void
    @ObservationIgnored private let signOut: @MainActor () async -> Void

    /// `delete` permanently deletes the account (it throws when it did not);
    /// `signOut` clears this device's session once the account is gone.
    public init(
        phase: AccountDeletionPhase = .idle,
        delete: @escaping @MainActor () async throws -> Void,
        signOut: @escaping @MainActor () async -> Void
    ) {
        self.phase = phase
        self.delete = delete
        self.signOut = signOut
    }

    /// The row is busy: no second request, no dismissing mid-request.
    public var isDeleting: Bool { phase == .deleting || phase == .deleted }

    public var isConfirming: Bool { phase == .confirming }

    public var failure: AccountDeletionFailure? {
        if case .failed(let failure) = phase { return failure }
        return nil
    }

    /// Delete Account tapped: show the confirmation.
    public func requestDeletion() {
        switch phase {
        case .idle, .failed: phase = .confirming
        case .confirming, .deleting, .deleted: break
        }
    }

    /// The confirmation's Cancel.
    public func cancel() {
        guard phase == .confirming else { return }
        phase = .idle
    }

    /// The confirmation's destructive Delete Account. The phase leaves
    /// `confirming` before this returns, so the alert never shows again
    /// while the request starts; the returned task ends with the flow.
    @discardableResult
    public func confirm() -> Task<Void, Never>? {
        guard phase == .confirming else { return nil }
        return start()
    }

    /// Try Again after a failure. The person confirmed already; it does not ask twice.
    @discardableResult
    public func retry() -> Task<Void, Never>? {
        guard failure != nil else { return nil }
        return start()
    }

    private func start() -> Task<Void, Never> {
        phase = .deleting
        // task-owner: one deletion request and its sign-out; ends with them
        return Task { await self.run() }
    }

    private func run() async {
        do {
            try await delete()
        } catch {
            phase = .failed(AccountDeletionFailure(error))
            return
        }
        phase = .deleted
        await signOut()
    }
}
