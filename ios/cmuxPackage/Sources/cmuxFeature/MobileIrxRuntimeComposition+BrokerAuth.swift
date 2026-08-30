import CmuxAuthRuntime
import CmuxIrohTransport

extension MobileIrxRuntimeComposition {
    /// Creates the account-pinned source shared by every iOS irx broker call.
    func brokerTokenSource(
        accountID: String,
        auth: AuthCoordinator
    ) -> CmxIrohBrokerTokenSource {
        return .accountPinned(
            to: accountID,
            snapshot: { [weak auth] in
                guard let auth else { return nil }
                do {
                    let session = try await auth.authenticatedSessionSnapshot()
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
            forceRefresh: { [weak auth] in
                guard let auth else {
                    throw CmxIrohBrokerTokenRecoveryError.transient
                }
                do {
                    _ = try await auth.forceRefreshAccessToken()
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
