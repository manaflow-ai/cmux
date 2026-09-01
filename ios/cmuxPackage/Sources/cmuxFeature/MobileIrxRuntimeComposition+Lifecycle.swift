import CmuxAuthRuntime
import CmuxIrxTransport

extension MobileIrxRuntimeComposition {
    /// Converts a definitive broker/auth rejection during initial provisioning
    /// into the same explicit state used by the credential autopilot. Returning
    /// `true` tells the launch poller to stop; a new authenticated session
    /// generation is the only implicit recovery trigger.
    @discardableResult
    func handleProvisioningFailure(
        _ error: any Error,
        session: AuthenticatedSessionSnapshot,
        broker: IrxBrokerService? = nil,
        endpoint: IrxEndpointSupervisor? = nil,
        ownerToken: UUID? = nil
    ) async -> Bool {
        let failure: IrxBrokerFailure?
        if let classified = error as? IrxBrokerFailure,
           classified.requiresReauthentication {
            failure = classified
        } else if let recovery = error as? CmxIrohBrokerTokenRecoveryError,
                  recovery == .authenticationRequired {
            failure = IrxBrokerFailure(operation: .register, error: recovery)
        } else if let authError = error as? AuthError,
                  authError == .unauthorized {
            failure = IrxBrokerFailure(
                operation: .register,
                error: CmxIrohBrokerTokenRecoveryError.authenticationRequired
            )
        } else {
            failure = nil
        }
        guard let failure,
              provisioningOwnerToken == (ownerToken ?? provisioningOwnerToken),
              provisionedAccountID == session.accountID,
              provisionedSessionGeneration == session.generation else {
            return false
        }
        guard await ownsProvisioning(
            session: session,
            broker: broker,
            endpoint: endpoint,
            allowSignedOut: failure.requiresReauthentication,
            ownerToken: ownerToken
        ) else { return false }
        cancelAutopilotRecovery()
        // Record the rejected owner before tearing resources down. This is
        // needed even when provisioning failed before `broker` was published.
        provisionedAccountID = session.accountID
        provisionedSessionGeneration = session.generation
        reauthenticationRequired = true
        var attributes = failure.journalAttributes
        attributes["state"] = "reauthentication_required"
        Self.journal.record(
            "client-runtime", "reauthentication-required", attributes)
        await resetForSignOut(preserveReauthentication: true)
        return true
    }

    /// Returns the credential-free state consumed by the iOS Settings row.
    public func irxAuthenticationState() async -> CmxIrxAuthenticationState {
        reauthenticationRequired ? .reauthenticationRequired : .ready
    }

    /// Publishes irx authentication transitions without exposing credentials.
    public func irxAuthenticationStateUpdates() async
        -> AsyncStream<CmxIrxAuthenticationState>
    {
        let id = UUID()
        let current = reauthenticationRequired
            ? CmxIrxAuthenticationState.reauthenticationRequired
            : .ready
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            authenticationStatusContinuations[id] = continuation
            continuation.yield(current)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeAuthenticationStatusContinuation(id) }
            }
        }
    }

    private func removeAuthenticationStatusContinuation(_ id: UUID) {
        authenticationStatusContinuations[id] = nil
    }

    /// Fences the owner before AuthCoordinator's force-refresh path can publish
    /// a signed-out identity. The marker is cleared by the matching completion
    /// callback or by a newer provisioning owner.
    func markBrokerAuthenticationRefreshStarted(
        session: AuthenticatedSessionSnapshot
    ) {
        guard provisionedAccountID == session.accountID,
              provisionedSessionGeneration == session.generation else { return }
        pendingBrokerAuthenticationRefreshOwnerToken = provisioningOwnerToken
    }

    /// Completes the force-refresh handoff. A definitive rejection is marked
    /// before the identity observer can tear down the captured owner; transient
    /// and successful refreshes release the marker and let a signed-out
    /// transition finish its ordinary teardown.
    func completeBrokerAuthenticationRefresh(
        session: AuthenticatedSessionSnapshot,
        requiresReauthentication: Bool
    ) async {
        guard pendingBrokerAuthenticationRefreshOwnerToken == provisioningOwnerToken,
              provisionedAccountID == session.accountID,
              provisionedSessionGeneration == session.generation else { return }
        pendingBrokerAuthenticationRefreshOwnerToken = nil
        if requiresReauthentication {
            reauthenticationRequired = true
            publishAuthenticationState()
            return
        }
        guard !reauthenticationRequired,
              let auth,
              await auth.authenticatedSessionIdentity == nil else { return }
        await resetForSignOut()
    }

    func publishAuthenticationState() {
        let state = reauthenticationRequired
            ? CmxIrxAuthenticationState.reauthenticationRequired
            : CmxIrxAuthenticationState.ready
        for continuation in authenticationStatusContinuations.values {
            continuation.yield(state)
        }
    }

    /// Reconciles account/session transitions without relying on a foreground
    /// event. A new generation is the only implicit recovery trigger after a
    /// rejected refresh; the old session is never retried in place.
    func handleAuthenticatedIdentity(
        _ identity: AuthenticatedSessionIdentity?
    ) async {
        guard let identity else {
            if pendingBrokerAuthenticationRefreshOwnerToken == provisioningOwnerToken {
                // A force-refresh rejection clears AuthCoordinator before its
                // broker failure callback can run. Leave the captured owner
                // intact until that callback records the definitive state.
                return
            }
            if reauthenticationRequired
                || broker != nil
                || provisionedAccountID != nil
                || provisionInFlight != nil {
                // AuthCoordinator can publish nil either while a rejected
                // refresh is being reported or while the normal sign-out hook
                // is still unwinding. Preserve the owner fence until the
                // corresponding handler/sign-out hook makes the final choice.
                await resetForSignOut(
                    preserveReauthentication: reauthenticationRequired
                )
            }
            return
        }
        if reauthenticationRequired {
            guard let expectedGeneration = provisionedSessionGeneration,
                  expectedGeneration != identity.generation else { return }
            await resetForSignOut()
            _ = await provisionIfPossible()
            return
        }
        if let provisionedAccountID,
           provisionedAccountID != identity.accountID {
            await resetForSignOut()
            _ = await provisionIfPossible()
            return
        }
        if broker == nil {
            _ = await provisionIfPossible()
        }
    }

    /// Creates the client credential autopilot and routes terminal failures to
    /// this composition's lifecycle owner.
    func makeAutopilot(
        broker: IrxBrokerService,
        endpoint: IrxEndpointSupervisor,
        session: AuthenticatedSessionSnapshot
    ) async -> IrxRelayCredentialAutopilot {
        let pilot = IrxRelayCredentialAutopilot(
            broker: broker,
            endpoint: endpoint,
            journal: Self.journal,
            retryPolicy: IrxHostActivationPolicy(
                retrySchedule: .foregroundClient,
                postRecoveryUnauthorizedFailureLimit: 4
            )
        )
        await pilot.setOnCredentialRotation { [weak self, broker, endpoint] in
            await self?.handleAutopilotRotation(
                session: session,
                broker: broker,
                endpoint: endpoint
            )
        }
        await pilot.setOnFailure { [weak self] failure, disposition in
            await self?.handleAutopilotFailure(
                failure,
                disposition: disposition,
                session: session,
                broker: broker,
                endpoint: endpoint
            )
        }
        await pilot.setOnRotation { [weak broker, weak endpoint] in
            guard let broker, let endpoint else { throw CancellationError() }
            // Registration initially carries no relay hint on iOS. Re-publish
            // the endpoint's actual home relay after every credential rotation
            // so paired Macs do not disappear when the broker hint expires.
            let relay = endpoint.homeRelayURL()
            try await broker.registerHintIfNeeded(
                pairingEnabled: false,
                relayURLHint: relay
            )
        }
        return pilot
    }

    /// Clears a pending terminal-failure kick after a successful rotation.
    func handleAutopilotRotation(
        session: AuthenticatedSessionSnapshot,
        broker: IrxBrokerService,
        endpoint: IrxEndpointSupervisor
    ) async {
        guard await isCurrentProvisioning(
            session: session, broker: broker, endpoint: endpoint
        ) else { return }
        autopilotRecoveryCount = 0
        cancelAutopilotRecovery()
        reauthenticationRequired = false
        publishAuthenticationState()
    }

    /// Detects the explicit sign-in transition that follows a rejected
    /// refresh. A new session generation is the safe point to rebuild the
    /// account-pinned broker; the old generation is never retried silently.
    func hasNewAuthenticatedSession() async -> Bool {
        guard reauthenticationRequired,
              let expectedGeneration = provisionedSessionGeneration,
              let auth,
              let current = try? await auth.authenticatedSessionSnapshot() else {
            return false
        }
        return current.generation != expectedGeneration
    }

    /// Handles a terminal credential-refresh failure without leaving a
    /// silently dead autopilot. Renewal either enters an explicit re-auth
    /// state or follows the bounded self-recovery ladder below.
    func handleAutopilotFailure(
        _ failure: IrxBrokerFailure,
        disposition: IrxRelayCredentialAutopilot.FailureDisposition,
        session: AuthenticatedSessionSnapshot,
        broker: IrxBrokerService,
        endpoint: IrxEndpointSupervisor
    ) async {
        Self.journal.record(
            "client-runtime", "autopilot-failed", failure.journalAttributes)
        guard case let .terminal(requiresReauthentication) = disposition else { return }
        if requiresReauthentication {
            guard await ownsProvisioning(
                session: session,
                broker: broker,
                endpoint: endpoint,
                allowSignedOut: true
            ) else { return }
            cancelAutopilotRecovery()
            provisionedAccountID = session.accountID
            provisionedSessionGeneration = session.generation
            reauthenticationRequired = true
            var attributes = failure.journalAttributes
            attributes["state"] = "reauthentication_required"
            Self.journal.record(
                "client-runtime", "reauthentication-required", attributes)
            await resetForSignOut(preserveReauthentication: true)
            return
        }
        // Keep the current endpoint intact and schedule a few bounded kicks.
        // A frontmost app cannot rely on another foreground transition to
        // restart renewal, so the lifecycle owns this short recovery ladder.
        guard await ownsProvisioning(
            session: session,
            broker: broker,
            endpoint: endpoint,
            allowSignedOut: false
        ) else { return }
        await autopilot?.stop()
        scheduleAutopilotRecovery(
            failure: failure,
            session: session,
            broker: broker,
            endpoint: endpoint
        )
        Self.journal.record(
            "client-runtime", "autopilot-paused-until-foreground")
    }

    /// Schedules cancellable foreground-rate kicks after a terminal,
    /// non-auth renewal failure. Successful rotation resets the ladder.
    private func scheduleAutopilotRecovery(
        failure: IrxBrokerFailure,
        session: AuthenticatedSessionSnapshot,
        broker: IrxBrokerService,
        endpoint: IrxEndpointSupervisor
    ) {
        guard autopilotRecoveryTask == nil else { return }
        guard autopilotRecoveryCount < 3 else {
            Self.journal.record(
                "client-runtime", "autopilot-recovery-exhausted",
                failure.journalAttributes
            )
            return
        }
        let delay = autopilotRecoveryPolicy.retrySchedule.delay(
            failureCount: autopilotRecoveryCount,
            retryAfterSeconds: nil,
            jitterUnitInterval: 0
        )
        autopilotRecoveryCount += 1
        let clock = autopilotRecoveryClock
        let deadline = clock.now().addingTimeInterval(delay)
        let recoveryID = UUID()
        autopilotRecoveryID = recoveryID
        Self.journal.record(
            "client-runtime", "autopilot-retry-scheduled",
            failure.journalAttributes.merging(
                ["delay_s": String(Int(delay.rounded()))],
                uniquingKeysWith: { _, latest in latest }
            )
        )
        autopilotRecoveryTask = Task { [weak self] in
            defer {
                if let self, self.autopilotRecoveryID == recoveryID {
                    self.autopilotRecoveryTask = nil
                    self.autopilotRecoveryID = nil
                }
            }
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  await self.isCurrentProvisioning(
                      session: session, broker: broker, endpoint: endpoint
                  ) else { return }
            await self.autopilot?.kick()
        }
    }

    /// Cancels a pending self-recovery kick without affecting the autopilot.
    func cancelAutopilotRecovery() {
        autopilotRecoveryTask?.cancel()
        autopilotRecoveryTask = nil
        autopilotRecoveryID = nil
    }

    /// Fences provisioning to one authenticated account at a time.
    func prepareForProvisioning(
        session: AuthenticatedSessionSnapshot
    ) async {
        if let provisionedAccountID,
           provisionedAccountID != session.accountID {
            await resetForSignOut()
        }
        if provisionedAccountID != session.accountID
            || provisionedSessionGeneration != session.generation {
            provisioningOwnerToken = UUID()
        }
        // Set both fields before ``provisionOnce()`` suspends so a late
        // failure cannot be attributed to a newer account/session.
        provisionedAccountID = session.accountID
        provisionedSessionGeneration = session.generation
    }

    /// Confirms that an asynchronous provisioning continuation still belongs
    /// to the same account and auth-session generation.
    func isCurrentProvisioning(session: AuthenticatedSessionSnapshot) async -> Bool {
        guard provisionedAccountID == session.accountID,
              let auth else { return false }
        return await auth.isAuthenticatedSessionIdentityCurrent(
            AuthenticatedSessionIdentity(
                generation: session.generation,
                accountID: session.accountID
            )
        )
    }

    /// Also verifies that the broker and endpoint captured by an auxiliary
    /// task are still the instances owned by this composition.
    func isCurrentProvisioning(
        session: AuthenticatedSessionSnapshot,
        broker: IrxBrokerService,
        endpoint: IrxEndpointSupervisor
    ) async -> Bool {
        guard await isCurrentProvisioning(session: session) else { return false }
        return self.broker === broker && endpointSupervisor === endpoint
    }

    /// Verifies the captured owner even when the auth coordinator has already
    /// published nil for the rejection being handled. A newer session or a
    /// reset invalidates the account/generation/instance fence first.
    func ownsProvisioning(
        session: AuthenticatedSessionSnapshot,
        broker: IrxBrokerService? = nil,
        endpoint: IrxEndpointSupervisor? = nil,
        allowSignedOut: Bool,
        ownerToken: UUID? = nil
    ) async -> Bool {
        guard provisioningOwnerToken == (ownerToken ?? provisioningOwnerToken),
              provisionedAccountID == session.accountID,
              provisionedSessionGeneration == session.generation else {
            return false
        }
        if let broker, self.broker !== broker { return false }
        if let endpoint, endpointSupervisor !== endpoint { return false }
        if await isCurrentProvisioning(session: session) { return true }
        guard allowSignedOut, let auth else { return false }
        return await auth.authenticatedSessionIdentity == nil
    }

    /// Stops irx-owned sessions before auth clears the account's credentials.
    ///
    /// The provisioning loop itself remains installed so a later sign-in can
    /// provision a new account. Current broker and auxiliary operations are
    /// cancelled before ownership is cleared; their session/instance fences
    /// make late completions harmless without blocking sign-out on a network
    /// request.
    public func resetForSignOut(
        preserveReauthentication: Bool = false
    ) async {
        provisioningOwnerToken = UUID()
        let retainedAccountID = preserveReauthentication
            ? provisionedAccountID : nil
        let retainedGeneration = preserveReauthentication
            ? provisionedSessionGeneration : nil
        if let provisionInFlight {
            provisionInFlight.cancel()
        }
        provisionInFlight = nil

        backgroundProvisioningTask?.cancel()
        backgroundProvisioningTask = nil
        cancelAutopilotRecovery()
        autopilotRecoveryCount = 0

        if let autopilot {
            await autopilot.stop()
        }
        autopilot = nil

        if let controlPlane {
            await controlPlane.stop()
        }
        controlPlane = nil
        // The dial gate is generation-scoped. Keep the durable lease until an
        // explicit sign-out clears it, but never let a retired composition
        // continue judging dials for the next account/session.
        deviceListBox.clear()
        deviceListStore = nil

        for engine in enginesByPeer.values {
            await engine.stop(code: .hostShutdown)
        }
        enginesByPeer.removeAll()
        routesByPeer.removeAll()
        claimedControlSessions.removeAll()
        claimedEventSessions.removeAll()

        if let endpointSupervisor {
            await endpointSupervisor.close()
        }
        endpointSupervisor = nil
        broker = nil
        identity = nil
        pendingBrokerAuthenticationRefreshOwnerToken = nil
        provisionedAccountID = retainedAccountID
        provisionedSessionGeneration = retainedGeneration
        reauthenticationRequired = preserveReauthentication
        publishAuthenticationState()
        Self.journal.record("client-runtime", "reset-for-sign-out")
    }
}
