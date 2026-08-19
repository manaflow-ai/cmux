import CMUXMobileCore
import CmuxAuthRuntime
import CmuxPeerTransport
import CmuxPeerTransportCore
import Foundation

/// Everything a post-auth-clear remote revocation needs, captured BEFORE the
/// local identity wipe: the binding id, the account it belonged to, and the
/// signed binding-request proof that authorizes the DELETE.
public struct MobilePeerSignOutPreparation: Sendable {
    let accountID: String?
    let bindingID: String?
    let bindingAuthorization: PeerBindingRequestAuthorization?
    let clientNamespace: String
}

/// Failure surfaced when a hidden computer cannot be forgotten.
enum MobileIrohForgetError: Error {
    /// No account is authenticated, so no bindings can be revoked.
    case notAuthenticated
    /// The authenticated account changed after the forget began, so the revoke
    /// was aborted rather than applied to a different account's bindings.
    case accountChanged
    /// The requested Mac belongs to another build lane.
    case incompatibleBuild
    /// The operation's total deadline elapsed before every matching binding was
    /// revoked. Already-applied revokes stand; retrying the forget re-discovers
    /// and revokes only what remains.
    case deadlineExceeded
}

/// Resume-once guard for the forget deadline race: whichever racer claims
/// first owns the continuation, and the loser's late completion is discarded.
private actor MobilePeerForgetRaceGate {
    private var claimed = false

    func claim() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }
}

extension MobilePeerRuntimeComposition {
    // MARK: - Sign-out

    /// Synchronously fences lifecycle work and starts local sign-out cleanup.
    ///
    /// The revocation proof (binding id plus signed request authorization) is
    /// captured BEFORE local identity state is wiped, so the captured-token
    /// hook can still revoke the binding after auth clears its tokens.
    ///
    /// - Returns: The shared preparation operation for this sign-out attempt.
    public func beginSignOutPreparation()
        -> Task<MobilePeerSignOutPreparation, Never>
    {
        if let signOutOperation {
            return signOutOperation
        }
        signOutInProgress = true
        let operation = Task { @MainActor [weak self] in
            guard let self else {
                return MobilePeerSignOutPreparation(
                    accountID: nil,
                    bindingID: nil,
                    bindingAuthorization: nil,
                    clientNamespace: "legacy"
                )
            }
            return await self.performSignOutPreparation()
        }
        signOutOperation = operation
        return operation
    }

    /// Waits for the shared local preparation operation.
    public func prepareSignOut() async -> MobilePeerSignOutPreparation {
        await beginSignOutPreparation().value
    }

    private func performSignOutPreparation() async -> MobilePeerSignOutPreparation {
        let accountID = activation?.accountID ?? observedAccountID
        let binding = activation?.binding
        var bindingAuthorization: PeerBindingRequestAuthorization?
        if let binding, let accountID {
            bindingAuthorization = try? await capturedBindingAuthorization(
                accountID: accountID,
                binding: binding
            )
        }
        lifecycleRevision &+= 1
        observedAuthState = MobileIrohAuthState(accountID: nil)
        await closeAllSessions(reason: "sign out")
        await supervisor.shutDown(reason: "sign out")
        accountBroker = nil
        discoveryProvider = nil
        clearActivationState()
        await wipeLocalState()
        diagnosticArchive?.clear()
        previousLaunchDiagnosticReport = .some(nil)
        await diagnosticLog?.clear()
        publishIrohSettingsUpdate()
        return MobilePeerSignOutPreparation(
            accountID: accountID,
            bindingID: binding?.bindingID,
            bindingAuthorization: bindingAuthorization,
            clientNamespace: clientNamespace
        )
    }

    /// Rebuilds the signed binding-request proof from the still-present local
    /// identity, before that identity is deactivated.
    private func capturedBindingAuthorization(
        accountID: String,
        binding: PeerBrokerBinding
    ) async throws -> PeerBindingRequestAuthorization {
        let appInstanceID = await appInstances.appInstanceID(
            accountID: accountID,
            tag: tag
        )
        let identity = try await identities.identity(
            accountID: accountID,
            appInstanceID: appInstanceID
        )
        guard identity.endpointID == binding.endpointID,
              identity.generation == binding.identityGeneration else {
            throw MobileIrohForgetError.accountChanged
        }
        return try PeerBindingRequestAuthorization(
            bindingID: binding.bindingID,
            clientNamespace: clientNamespace,
            identity: identity,
            endpointID: identity.endpointID
        )
    }

    /// Completes remote revocation after auth has already cleared local tokens.
    ///
    /// Cancellation stops waiting immediately while the credential-free local
    /// preparation continues in its own task.
    public func completeSignOutAfterAuthClear(
        _ operation: Task<MobilePeerSignOutPreparation, Never>,
        accessToken: String?,
        refreshToken: String?
    ) async {
        guard let preparation = await cancellationAwareValue(of: operation) else {
            return
        }
        await revokeAfterSignOut(
            preparation,
            accessToken: accessToken,
            refreshToken: refreshToken
        )
    }

    /// Best-effort revokes the prepared binding with auth's captured token pair.
    ///
    /// Remote failure is logged and never reconstructs local endpoint or cache
    /// state.
    public func revokeAfterSignOut(
        _ preparation: MobilePeerSignOutPreparation,
        accessToken: String?,
        refreshToken: String?
    ) async {
        defer {
            signOutOperation = nil
            signOutInProgress = false
            Task { @MainActor [weak self] in
                await self?.reconcileLiveAuthIfNeeded()
            }
        }
        guard let bindingID = preparation.bindingID,
              let accessToken,
              !accessToken.isEmpty,
              let refreshToken,
              !refreshToken.isEmpty,
              let brokerBaseURL else {
            return
        }
        do {
            // The pair was captured together up front, so it is coherent by
            // construction.
            let broker = try PeerTrustBrokerClient(
                baseURL: brokerBaseURL,
                tokenProvider: PeerBrokerTokenProvider(
                    capture: {
                        PeerBrokerCredentials(
                            accessToken: accessToken,
                            refreshToken: refreshToken
                        )
                    },
                    forceRefresh: {}
                ),
                clientNamespace: preparation.clientNamespace,
                bindingAuthorization: preparation.bindingAuthorization
            )
            try await broker.revokeBinding(bindingID, intent: .own)
        } catch is CancellationError {
            return
        } catch {
            mobilePeerLog.error(
                "Peer binding revoke failed: \(String(describing: error), privacy: .private)"
            )
        }
    }

    private func cancellationAwareValue(
        of operation: Task<MobilePeerSignOutPreparation, Never>
    ) async -> MobilePeerSignOutPreparation? {
        let stream = AsyncStream<MobilePeerSignOutPreparation> { continuation in
            let waiter = Task { @MainActor in
                let value = await operation.value
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                continuation.yield(value)
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                waiter.cancel()
            }
        }
        for await value in stream {
            return value
        }
        return nil
    }

    // MARK: - Forget computer

    /// Revokes every non-revoked binding for one saved computer.
    ///
    /// Uses a direct authenticated broker (no endpoint required beyond the
    /// current activation's binding proof), so an offline Mac's binding is
    /// still listed by discovery and can be revoked. Matches by canonical
    /// device id, and by exact tag when the caller knows the app instance,
    /// then revokes each match. A no-match discovery is treated as
    /// already-forgotten and succeeds.
    public func forgetComputer(
        macDeviceID: String,
        instanceTag: String?,
        expectedAccountID: String
    ) async throws {
        // Race the WHOLE forget against the deadline WITHOUT structurally
        // awaiting the loser: a revoke suspended on a dependency that ignores
        // cooperative cancellation must not keep the forget (and its UI busy
        // state) stuck past the deadline. Already-applied revokes stand and a
        // retry re-discovers only what remains.
        let gate = MobilePeerForgetRaceGate()
        let outcome = await withCheckedContinuation { (
            continuation: CheckedContinuation<Result<Void, any Error>?, Never>
        ) in
            let work = Task { [weak self] in
                let result: Result<Void, any Error>
                do {
                    guard let self else { throw MobileIrohForgetError.notAuthenticated }
                    try await self.revokeMatchingBindings(
                        macDeviceID: macDeviceID,
                        instanceTag: instanceTag,
                        expectedAccountID: expectedAccountID
                    )
                    result = .success(())
                } catch {
                    result = .failure(error)
                }
                if await gate.claim() {
                    continuation.resume(returning: result)
                }
            }
            Task {
                try? await Self.forgetDeadlineSleep(Self.forgetRevokeDeadlineSeconds)
                if await gate.claim() {
                    work.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
        guard let outcome else { throw MobileIrohForgetError.deadlineExceeded }
        try outcome.get()
    }

    private func revokeMatchingBindings(
        macDeviceID: String,
        instanceTag: String?,
        expectedAccountID: String
    ) async throws {
        guard let auth else { throw MobileIrohForgetError.notAuthenticated }
        if let instanceTag, !isCompatibleMacTag(instanceTag) {
            throw MobileIrohForgetError.incompatibleBuild
        }
        // Capture the account identity AND both tokens as one consistent
        // snapshot from a single auth-session generation, so the revoke acts
        // with credentials that provably belong to `expectedAccountID`.
        let session: AuthenticatedSessionSnapshot
        do {
            session = try await auth.authenticatedSessionSnapshot()
        } catch {
            throw MobileIrohForgetError.notAuthenticated
        }
        guard session.accountID == expectedAccountID else {
            throw MobileIrohForgetError.accountChanged
        }
        guard let activation, activation.accountID == expectedAccountID,
              let brokerBaseURL else {
            throw MobileIrohForgetError.notAuthenticated
        }
        let bindingAuthorization = try await capturedBindingAuthorization(
            accountID: expectedAccountID,
            binding: activation.binding
        )
        let broker = try PeerTrustBrokerClient(
            baseURL: brokerBaseURL,
            tokenProvider: pinnedSessionTokenProvider(session),
            clientNamespace: clientNamespace,
            bindingAuthorization: bindingAuthorization
        )
        let snapshot = try await broker.discover()
        // The authenticated session can change while discover() is in flight.
        // Revoking now would target the NEW session's bindings, so re-validate
        // before any mutation.
        try ensureSessionUnchanged(
            generation: session.generation,
            expectedAccountID: expectedAccountID
        )
        let canonicalTarget = cmxCanonicalDeviceID(macDeviceID)
        let matches = snapshot.bindings.filter { binding in
            guard cmxCanonicalDeviceID(binding.deviceID) == canonicalTarget else {
                return false
            }
            return isCompatibleMacTag(binding.tag)
                && (instanceTag == nil || binding.tag == instanceTag)
        }
        // Bound the WHOLE operation. Each revoke request carries its own
        // network timeout, so a large sequential loop could keep the forget
        // busy for tens of minutes. Past the deadline, stop and surface the
        // failure.
        let deadline = now().addingTimeInterval(Self.forgetRevokeDeadlineSeconds)
        for binding in matches {
            guard now() < deadline else {
                throw MobileIrohForgetError.deadlineExceeded
            }
            try ensureSessionUnchanged(
                generation: session.generation,
                expectedAccountID: expectedAccountID
            )
            try await broker.revokeBinding(binding.bindingID, intent: .forgetMac)
        }
    }

    func isCompatibleMacTag(_ candidate: String?) -> Bool {
        if let discoveryCompatibilityPolicy {
            return discoveryCompatibilityPolicy.allows(instanceTag: candidate)
        }
        let normalized = candidate?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == tag.lowercased()
    }

    /// Total wall-clock budget for one forget's revoke loop. Six sequential
    /// worst-case broker timeouts fit comfortably; a healthy broker revokes
    /// dozens of bindings well within it.
    static let forgetRevokeDeadlineSeconds: TimeInterval = 60

    /// Cancellable sleeper backing the forget deadline race — an intentional
    /// bounded timeout (cancelled with the race, never a synchronization
    /// substitute). Static because extensions cannot hold instance storage.
    static let forgetDeadlineSleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Throws if the authenticated session that initiated the forget was
    /// replaced, so a revoke can never land on a different session's bindings.
    private func ensureSessionUnchanged(
        generation: UInt64,
        expectedAccountID: String
    ) throws {
        guard sessionMatches(generation: generation, accountID: expectedAccountID) else {
            throw MobileIrohForgetError.accountChanged
        }
    }

    /// Whether the live auth session is still the exact one (generation +
    /// account) the forget pinned to.
    private func sessionMatches(generation: UInt64, accountID: String) -> Bool {
        guard let auth else { return false }
        return auth.authSessionGeneration == generation && auth.currentUser?.id == accountID
    }

    /// Broker token source that reuses the ONE coherent credential pair
    /// captured when the forget started, for every broker leg. A mid-forget
    /// sign-out or account switch fails the local check and yields `nil`, so
    /// the revoke fails safely rather than acting as the wrong user.
    private func pinnedSessionTokenProvider(
        _ session: AuthenticatedSessionSnapshot
    ) -> PeerBrokerTokenProvider {
        PeerBrokerTokenProvider(
            capture: { @MainActor [weak self] in
                guard let self,
                      self.sessionMatches(
                          generation: session.generation,
                          accountID: session.accountID
                      ) else { return nil }
                return PeerBrokerCredentials(
                    accessToken: session.accessToken,
                    refreshToken: session.refreshToken
                )
            },
            forceRefresh: {}
        )
    }
}
