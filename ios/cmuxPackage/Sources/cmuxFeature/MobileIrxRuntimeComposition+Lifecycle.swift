import CmuxAuthRuntime
import CmuxIrxTransport

extension MobileIrxRuntimeComposition {
    /// Returns the credential-free state consumed by the iOS Settings row.
    public func irxAuthenticationState() async -> CmxIrxAuthenticationState {
        reauthenticationRequired ? .reauthenticationRequired : .ready
    }

    /// Publishes irx authentication transitions without exposing credentials.
    public func irxAuthenticationStateUpdates()
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
            if broker != nil || reauthenticationRequired {
                await resetForSignOut()
            }
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
            return
        }
        guard reauthenticationRequired,
              provisionedSessionGeneration != identity.generation else { return }
        await resetForSignOut()
        _ = await provisionIfPossible()
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
                retrySchedule: .foregroundClient
            )
        )
        await pilot.setOnFailure { [weak self] failure, disposition in
            await self?.handleAutopilotFailure(
                failure,
                disposition: disposition,
                session: session,
                broker: broker,
                endpoint: endpoint
            )
        }
        await pilot.setOnRotation { [weak self, broker, endpoint] in
            guard let self else { throw CancellationError() }
            await self.handleAutopilotRotation(
                session: session,
                broker: broker,
                endpoint: endpoint
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
              let accountID = provisionedAccountID,
              let auth,
              let current = try? await auth.authenticatedSessionSnapshot() else {
            return false
        }
        return current.accountID == accountID
            && current.generation != expectedGeneration
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
            guard await isCurrentProvisioning(
                session: session,
                broker: broker,
                endpoint: endpoint
            ) else { return }
            await autopilot?.stop()
            cancelAutopilotRecovery()
            reauthenticationRequired = true
            publishAuthenticationState()
            var attributes = failure.journalAttributes
            attributes["state"] = "reauthentication_required"
            Self.journal.record(
                "client-runtime", "reauthentication-required", attributes)
            return
        }
        // Keep the current endpoint intact and schedule a few bounded kicks.
        // A frontmost app cannot rely on another foreground transition to
        // restart renewal, so the lifecycle owns this short recovery ladder.
        guard await isCurrentProvisioning(
            session: session,
            broker: broker,
            endpoint: endpoint
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
    func prepareForProvisioning(accountID: String) async {
        if let provisionedAccountID,
           provisionedAccountID != accountID {
            await resetForSignOut()
        }
        // Set this before ``provisionOnce()`` suspends so an account switch
        // cannot publish the old account's broker after a late completion.
        provisionedAccountID = accountID
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

    /// Stops irx-owned sessions before auth clears the account's credentials.
    ///
    /// The provisioning loop itself remains installed so a later sign-in can
    /// provision a new account. Current broker and auxiliary operations are
    /// cancelled before ownership is cleared; their session/instance fences
    /// make late completions harmless without blocking sign-out on a network
    /// request.
    public func resetForSignOut() async {
        if let provisionInFlight {
            provisionInFlight.cancel()
        }
        provisionInFlight = nil

        backgroundProvisioningTask?.cancel()
        backgroundProvisioningTask = nil
        cancelAutopilotRecovery()
        autopilotRecoveryCount = 0
        reauthenticationRequired = false
        publishAuthenticationState()

        if let autopilot {
            await autopilot.stop()
        }
        autopilot = nil

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
        provisionedAccountID = nil
        provisionedSessionGeneration = nil
        Self.journal.record("client-runtime", "reset-for-sign-out")
    }
}
