import CmuxIrxTransport

extension MobileIrxRuntimeComposition {
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

    /// Stops irx-owned sessions before auth clears the account's credentials.
    ///
    /// The provisioning loop itself remains installed so a later sign-in can
    /// provision a new account. Its current broker operation is cancelled and
    /// drained first, which prevents the old account's broker from being
    /// retained when the next account starts.
    public func resetForSignOut() async {
        if let provisionInFlight {
            provisionInFlight.cancel()
            _ = try? await provisionInFlight.value
        }
        provisionInFlight = nil

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
