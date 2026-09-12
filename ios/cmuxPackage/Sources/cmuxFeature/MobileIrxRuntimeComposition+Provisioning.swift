import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxIrxTransport
import Foundation

extension MobileIrxRuntimeComposition {
    /// Builds and warms the account-pinned broker/endpoint stack. Publication
    /// is all-or-nothing: a late auth transition cannot retain a half-built
    /// client or rebind an endpoint for a retired session.
    func provisionOnce(
        session: AuthenticatedSessionSnapshot
    ) async throws -> IrxBrokerService {
        guard let auth, let brokerBaseURL else {
            throw CompositionError.notSignedIn
        }
        guard await isCurrentProvisioning(session: session) else {
            throw CancellationError()
        }
        // IDENTITY ADOPTION: same identity/device/app-instance as the legacy
        // stack, so the binding refreshes in place and stored routes + pair
        // grants stay valid across the transport switch.
        guard let legacyComposition,
            let adopted = try await legacyComposition.irxAdoptedIdentity(
                accountID: session.accountID, tag: tag)
        else {
            throw CompositionError.notSignedIn
        }
        let identity = IrxIdentity(
            privateKeyData: adopted.material.secretKey.bytes,
            deviceID: adopted.deviceID,
            appInstanceID: adopted.appInstanceID
        )
        let broker = try IrxBrokerService(
            configuration: .init(
                baseURL: brokerBaseURL,
                clientNamespace: clientNamespace,
                tag: tag,
                platform: .ios,
                displayName: nil,
                cacheDirectory: stateDirectory,
                identityGeneration: adopted.material.generation,
                accountID: session.accountID,
                keychainAccessGroup: keychainAccessGroup
            ),
            identity: identity,
            tokenSource: auth.accountPinnedIrohBrokerTokenSource(
                accountID: session.accountID,
                onForceRefreshStart: { [weak self] in
                    await self?.markBrokerAuthenticationRefreshStarted(
                        session: session
                    )
                },
                onForceRefreshCompletion: { [weak self] requiresReauthentication in
                    await self?.completeBrokerAuthenticationRefresh(
                        session: session,
                        requiresReauthentication: requiresReauthentication
                    )
                }
            ),
            journal: Self.journal
        )
        let supervisor = IrxEndpointSupervisor(
            configuration: .init(
                identity: identity,
                pathMode: Self.forceRelayOnly ? .relayOnly : .automatic,
                preferredBindAddress: nil,
                // The Mac opens no bidi streams toward the phone; the events
                // lane is unidirectional and credited post-admission.
                initialRemoteBiStreams: 0,
                initialRemoteUniStreams: 0
            ),
            journal: Self.journal
        )
        let pilot = await makeAutopilot(
            broker: broker,
            endpoint: supervisor,
            session: session
        )
        // When cached state is fresh, refresh registration/discovery after the
        // live objects are published so launch does not pay those round trips.
        let cachedBinding = await broker.cachedBinding()
        let cachedTrust = await broker.cachedTrust()
        let cachedCredentials = await broker.cachedRelayCredentials()
        var refreshRegistrationInBackground = false
        var refreshDiscoveryInBackground = false
        if cachedBinding == nil || cachedTrust == nil {
            _ = try await broker.register(pairingEnabled: false, relayURLHint: nil)
            _ = try await pilot.usableCredentials()
            _ = try? await broker.discover()
        } else if cachedCredentials.isEmpty {
            // Registration arms this instance's binding proof before minting.
            _ = try await broker.register(pairingEnabled: false, relayURLHint: nil)
            refreshDiscoveryInBackground = true
        } else {
            refreshRegistrationInBackground = true
            refreshDiscoveryInBackground = true
        }
        let credentials = try await pilot.usableCredentials()
        guard await isCurrentProvisioning(session: session) else {
            throw CancellationError()
        }
        reauthenticationRequired = false
        publishAuthenticationState()
        autopilotRecoveryCount = 0
        cancelAutopilotRecovery()
        self.identity = identity
        self.provisionedAccountID = session.accountID
        self.provisionedSessionGeneration = session.generation
        self.broker = broker
        endpointSupervisor = supervisor
        autopilot = pilot
        await pilot.start()
        // `start()` can suspend while auth/sign-out tears down this owner.
        // Fence the returned pilot before any background task can use it.
        guard await isCurrentProvisioning(
            session: session,
            broker: broker,
            endpoint: supervisor
        ) else {
            await pilot.stop()
            throw CancellationError()
        }

        // Restore the account-scoped device-list lease before any dial can be
        // requested. The control-plane socket then refreshes this in-memory
        // gate with signed directory facts without blocking provisioning.
        let listStore = IrxDeviceListStore(
            secureStore: Self.deviceListSecureStore(
                stateDirectory: stateDirectory,
                keychainAccessGroup: keychainAccessGroup
            ),
            accountID: session.accountID,
            backendHost: brokerBaseURL.host() ?? "unknown-broker",
            journal: Self.journal
        )
        deviceListStore = listStore
        if let persisted = await listStore.loadPersisted() {
            deviceListBox.replace(persisted)
            await projectDeviceListForUI(persisted)
        }
        startControlPlane(identity: identity)

        // Fire-and-forget refresh/warm-up work is retained and fenced so
        // sign-out can cancel it without allowing a late endpoint bind.
        let refreshRegistration = refreshRegistrationInBackground
        let refreshDiscovery = refreshDiscoveryInBackground
        backgroundProvisioningTask?.cancel()
        let backgroundTask = Task { [weak self, broker, supervisor] in
            let ownerToken = await self?.provisioningOwnerToken
            let refreshTask = Task { [weak self, broker] in
                guard let self,
                      await self.isCurrentProvisioning(
                          session: session, broker: broker, endpoint: supervisor
                      ) else { return }
                if refreshRegistration {
                    do {
                        _ = try await broker.register(
                            pairingEnabled: false, relayURLHint: nil)
                    } catch {
                        if await self.handleProvisioningFailure(
                            error,
                            session: session,
                            broker: broker,
                            endpoint: supervisor,
                            ownerToken: ownerToken
                        ) {
                            return
                        }
                        Self.journal.record(
                            "client-runtime", "background-registration-failed",
                            (error as? IrxBrokerFailure)?.journalAttributes ?? [
                                "error": String(describing: error)
                            ]
                        )
                    }
                }
                guard await self.isCurrentProvisioning(
                    session: session, broker: broker, endpoint: supervisor
                ) else { return }
                if refreshDiscovery {
                    do {
                        _ = try await broker.discover()
                    } catch {
                        if await self.handleProvisioningFailure(
                            error,
                            session: session,
                            broker: broker,
                            endpoint: supervisor,
                            ownerToken: ownerToken
                        ) {
                            return
                        }
                        Self.journal.record(
                            "client-runtime", "background-discovery-failed",
                            (error as? IrxBrokerFailure)?.journalAttributes ?? [
                                "error": String(describing: error)
                            ]
                        )
                    }
                }
            }
            let warmupTask = Task { [weak self, supervisor] in
                guard let self,
                      await self.isCurrentProvisioning(
                          session: session, broker: broker, endpoint: supervisor
                      ) else { return }
                _ = try? await supervisor.readyEndpoint(credentials: credentials)
            }
            await withTaskCancellationHandler(operation: {
                await refreshTask.value
                await warmupTask.value
            }, onCancel: {
                refreshTask.cancel()
                warmupTask.cancel()
            })
        }
        backgroundProvisioningTask = backgroundTask
        return broker
    }
}
