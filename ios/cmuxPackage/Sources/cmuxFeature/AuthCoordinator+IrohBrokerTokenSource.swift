import CmuxAuthRuntime
import CmuxIrohTransport

/// Shared iOS construction for an account-pinned broker token source.
///
/// Both the legacy and irx compositions use this instance method so the
/// one-refresh-on-401 contract, account pin, and auth-error mapping cannot
/// drift between runtimes.
@MainActor
extension AuthCoordinator {
    func accountPinnedIrohBrokerTokenSource(
        accountID: String
    ) -> CmxIrohBrokerTokenSource {
        .accountPinned(
            to: accountID,
            snapshot: { [weak self] in
                guard let self else { return nil }
                do {
                    let session = try await self.authenticatedSessionSnapshot()
                    return CmxIrohAccountCredentialSnapshot(
                        accountID: session.accountID,
                        credentials: CmxIrohBrokerCredentials(
                            accessToken: session.accessToken,
                            refreshToken: session.refreshToken
                        )
                    )
                } catch AuthError.unauthorized {
                    return nil
                }
            },
            forceRefresh: { [weak self] in
                guard let self else {
                    throw CmxIrohBrokerTokenRecoveryError.transient
                }
                do {
                    _ = try await self.forceRefreshAccessToken()
                } catch AuthError.unauthorized {
                    throw CmxIrohBrokerTokenRecoveryError.authenticationRequired
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw CmxIrohBrokerTokenRecoveryError.transient
                }
            }
        )
    }
}
