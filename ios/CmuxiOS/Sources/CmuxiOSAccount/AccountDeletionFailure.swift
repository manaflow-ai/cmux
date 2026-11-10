import CmuxAuthRuntime

/// Why a deletion did not finish, as the person reads it.
public enum AccountDeletionFailure: Equatable, Sendable {
    /// Nothing reached the service (no network).
    case offline
    /// The request may have reached the service, but no answer said it finished.
    case unconfirmed
    /// The session is no longer valid; deletion needs a fresh sign-in.
    case sessionExpired
    /// The service refused or failed the deletion.
    case refused

    /// Maps what the deletion request threw.
    public init(_ error: any Error) {
        switch error as? AccountDeletionRequestError {
        case .localTransportFailure?:
            self = .offline
        case .timedOut?, .completionUnknown?, .stackDeleteIncomplete?:
            self = .unconfirmed
        case .unauthorized?:
            self = .sessionExpired
        default:
            self = .refused
        }
    }

    public var message: String {
        switch self {
        case .offline: AccountText.failedOffline
        case .unconfirmed: AccountText.failedUnconfirmed
        case .sessionExpired: AccountText.failedSessionExpired
        case .refused: AccountText.failedRefused
        }
    }
}
