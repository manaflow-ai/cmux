import CmuxAuthRuntime
import CmuxIrxTransport

extension MobileIrxRuntimeComposition {
    /// Creates the client credential autopilot and routes terminal failures to
    /// this composition's lifecycle owner.
    func makeAutopilot(
        broker: IrxBrokerService,
        endpoint: IrxEndpointSupervisor
    ) async -> IrxRelayCredentialAutopilot {
        let pilot = IrxRelayCredentialAutopilot(
            broker: broker, endpoint: endpoint, journal: Self.journal)
        await pilot.setOnFailure { [weak self] failure, disposition in
            await self?.handleAutopilotFailure(failure, disposition: disposition)
        }
        return pilot
    }

    /// Handles a terminal credential-refresh failure without leaving a
    /// silently dead autopilot. Renewal pauses until the next explicit
    /// foreground/auth recovery.
    func handleAutopilotFailure(
        _ failure: IrxBrokerFailure,
        disposition: IrxRelayCredentialAutopilot.FailureDisposition
    ) async {
        Self.journal.record(
            "client-runtime", "autopilot-failed", failure.journalAttributes)
        guard case .terminal = disposition else { return }
        // Keep the current endpoint intact and pause renewal. The existing
        // foreground lifecycle calls ``kick()`` again, so this terminal path
        // cannot rebuild/register in a tight loop while the user is offline or
        // resolving an account/policy issue.
        await autopilot?.stop()
        Self.journal.record(
            "client-runtime", "autopilot-paused-until-foreground")
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
        Self.journal.record("client-runtime", "reset-for-sign-out")
    }
}
