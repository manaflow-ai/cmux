import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxIrxTransport
import Foundation

extension MobileIrxRuntimeComposition {
    /// Builds and warms the account-pinned broker/endpoint stack. Publication
    /// is all-or-nothing: a late auth transition cannot retain a half-built
    /// client or rebind an endpoint for a retired session.
    func provisionOnce() async throws -> IrxBrokerService {
        guard let auth, let brokerBaseURL else {
            throw CompositionError.notSignedIn
        }
        let session = try await auth.authenticatedSessionSnapshot()
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
                identityGeneration: adopted.material.generation
            ),
            identity: identity,
            tokenSource: brokerTokenSource(accountID: session.accountID, auth: auth),
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
        self.identity = identity
        self.provisionedAccountID = session.accountID
        self.broker = broker
        endpointSupervisor = supervisor
        autopilot = pilot
        await pilot.start()

        // Fire-and-forget refresh/warm-up work is retained and fenced so
        // sign-out can cancel it without allowing a late endpoint bind.
        let refreshRegistration = refreshRegistrationInBackground
        let refreshDiscovery = refreshDiscoveryInBackground
        backgroundProvisioningTask?.cancel()
        let backgroundTask = Task { [weak self, broker, supervisor] in
            guard let self,
                  await self.isCurrentProvisioning(
                      session: session, broker: broker, endpoint: supervisor
                  ) else { return }
            if refreshRegistration {
                _ = try? await broker.register(pairingEnabled: false, relayURLHint: nil)
            }
            guard await self.isCurrentProvisioning(
                session: session, broker: broker, endpoint: supervisor
            ) else { return }
            if refreshDiscovery {
                _ = try? await broker.discover()
            }
            guard await self.isCurrentProvisioning(
                session: session, broker: broker, endpoint: supervisor
            ) else { return }
            _ = try? await supervisor.readyEndpoint(credentials: credentials)
        }
        backgroundProvisioningTask = backgroundTask
        return broker
    }
}
