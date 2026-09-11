public import CmuxAuthRuntime
import CmuxIrxTransport
import Foundation

extension MobileIrxRuntimeComposition {
    /// Observes account/team authority for the lifetime of the app.
    public func configure(auth: AuthCoordinator) async {
        guard authTask == nil else { return }
        self.auth = auth
        journal.record("v2-lifecycle", "launch")
        authTask = Task { [weak self, weak auth] in
            guard let auth else { return }
            await auth.awaitBootstrapped()
            for await scope in await auth.authenticatedTeamScopes() {
                guard !Task.isCancelled else { return }
                await self?.activate(scope)
            }
        }
    }

    func activate(_ scope: AuthenticatedTeamScope?) async {
        guard scope != activeScope else { return }
        epoch &+= 1
        let currentEpoch = epoch
        activeScope = scope
        await clearCurrentRuntime()
        guard epoch == currentEpoch, let scope else { return }
        provisionTask = Task { [weak self] in
            var delay: TimeInterval = 1
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.provision(scope: scope, epoch: currentEpoch)
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    await self.provisionFailed(epoch: currentEpoch)
                    try? await Task.sleep(for: .seconds(delay))
                    delay = min(delay * 2, 30)
                }
            }
        }
    }

    func provisionFailed(epoch currentEpoch: UInt64) {
        guard epoch == currentEpoch else { return }
        lastFailure = "The connection service could not start. It will retry."
        journal.record("v2-lifecycle", "setup-retry")
        publish()
    }

    func provision(scope: AuthenticatedTeamScope, epoch currentEpoch: UInt64) async throws {
        try await assertScope(scope, epoch: currentEpoch)
        let deviceID = try await installation.deviceID()
        let tuple = V2Identity(appNamespace: configuration.appNamespace, buildTag: tag,
            deviceID: deviceID, environment: configuration.environment,
            projectID: configuration.projectID, teamID: scope.teamID, userID: scope.session.accountID)
        let key = try await installation.key(identity: tuple)
        // A corrupt disposable cache is recoverable through a signed v2 setup;
        // the identity seed and Stack authentication are never erased.
        let restored = try? await stateStore.load(identity: tuple)
        try await assertScope(scope, epoch: currentEpoch)
        let identity = IrxIdentity(privateKeyData: key.secretKey, deviceID: deviceID, appInstanceID: key.endpointID)
        let supervisor = IrxEndpointSupervisor(configuration: IrxEndpointConfiguration(
            identity: identity, pathMode: forceRelayOnly ? .relayOnly : .automatic,
            initialRemoteBiStreams: 0, initialRemoteUniStreams: 0), journal: journal)
        self.identity = identity
        endpointSupervisor = supervisor
        cache = restored ?? V2CachedState(identity: tuple)
        publish()
        // Cached IROH binding never waits for a backend handshake or Stack refresh.
        if let restored, !restored.authorityRevoked {
            let credentials = Self.credentials(restored)
            if credentials.contains(where: { $0.isUsable(at: Date()) }) {
                endpointWarmupTask = Task { [weak self] in
                    do {
                        _ = try await supervisor.readyEndpoint(credentials: credentials)
                        try await self?.assertScope(scope, epoch: currentEpoch)
                        await self?.recordEndpointReady(cached: true)
                    } catch { /* The next dial/credential update retries through the same supervisor. */ }
                }
            }
        }
        let device = V2DeviceDescriptor(endpointID: key.endpointID, identity: tuple,
            identityGeneration: restored?.device?.descriptor.identityGeneration ?? 1,
            metadata: V2DeviceMetadata(appVersion: configuration.appVersion,
                capabilities: ["irx-v2"], displayName: configuration.displayName,
                pairingEnabled: true, platform: .ios, relayURLs: []))
        guard let auth else { throw CompositionError.notSignedIn }
        let session = urlSession
        let http = V2URLSessionHTTPTransport(session: session)
        let dependencies = V2ControlDependencies(
            connect: { request in V2URLSessionSocket(session: session, request: request) },
            http: { request in try await http.send(request) },
            stackAccessToken: { force in
                try await Self.accessToken(auth: auth, scope: scope, force: force)
            },
            sign: { data in
                guard await auth.isAuthenticatedTeamScopeCurrent(scope) else { throw CompositionError.scopeChanged }
                return try key.sign(data)
            })
        let service = V2ControlService(configuration: try V2ControlConfiguration(
            baseURL: configuration.baseURL, device: device), dependencies: dependencies, store: stateStore)
        try await assertScope(scope, epoch: currentEpoch)
        control = service
        controlTask = Task { [weak self] in
            for await snapshot in await service.events() {
                guard !Task.isCancelled else { return }
                await self?.apply(snapshot, scope: scope, epoch: currentEpoch)
            }
        }
        await service.start()
        try await assertScope(scope, epoch: currentEpoch)
        journal.record("v2-lifecycle", "control-started", ["cached": String(restored != nil)])
    }

    @MainActor
    static func accessToken(auth: AuthCoordinator, scope: AuthenticatedTeamScope, force: Bool) async throws -> String {
        guard auth.isAuthenticatedTeamScopeCurrent(scope) else { throw CompositionError.scopeChanged }
        let token: String
        if force { token = try await auth.forceRefreshAccessToken() }
        else { token = try await auth.authenticatedSessionSnapshot().accessToken }
        guard auth.isAuthenticatedTeamScopeCurrent(scope) else { throw CompositionError.scopeChanged }
        return token
    }

    func apply(_ snapshot: V2ControlSnapshot, scope: AuthenticatedTeamScope, epoch currentEpoch: UInt64) async {
        guard (try? await assertScope(scope, epoch: currentEpoch)) != nil else { return }
        // The service publishes its empty initial state before reading the same cache.
        guard snapshot.cache.device != nil || cache?.device == nil || snapshot.cache.authorityRevoked else { return }
        let previousCredentials = cache?.relayCredentials
        cache = snapshot.cache
        lastFailure = snapshot.failure.map { String(describing: $0) }
        publish()
        if snapshot.cache.authorityRevoked {
            let engines = Array(enginesByPeer.values)
            let supervisor = endpointSupervisor
            let directSupervisor = directEndpointSupervisor
            endpointWarmupTask?.cancel()
            endpointWarmupTask = nil
            for engine in engines { await engine.stop(code: .revoked) }
            await supervisor?.deactivate()
            await directSupervisor?.deactivate()
            guard (try? await assertScope(scope, epoch: currentEpoch)) != nil else { return }
            journal.record("v2-lifecycle", "authority-revoked")
            return
        }
        if let directory = snapshot.cache.directory {
            let permitted = Set(directory.devices.filter { !$0.revoked }.map { $0.descriptor.endpointID })
            for (peer, engine) in enginesByPeer where !permitted.contains(peer) {
                await engine.stop(code: .revoked)
            }
            guard (try? await assertScope(scope, epoch: currentEpoch)) != nil else { return }
            journal.record("v2-directory", "installed", ["count": String(directory.devices.count),
                "revision": String(directory.revision), "launchMs": String(Int(Date().timeIntervalSince(launchTime) * 1000))])
        }
        guard previousCredentials != snapshot.cache.relayCredentials,
              !snapshot.cache.relayCredentials.isEmpty, let supervisor = endpointSupervisor else { return }
        do {
            let credentials = Self.credentials(snapshot.cache)
            await supervisor.rotateCredentials(credentials)
            try await assertScope(scope, epoch: currentEpoch)
            _ = try await supervisor.readyEndpoint(credentials: credentials)
            try await assertScope(scope, epoch: currentEpoch)
            journal.record("v2-credentials", "installation-requested", ["count": String(credentials.count),
                "admittedSessions": String(admittedSessionCount)])
            recordEndpointReady(cached: false)
        } catch {
            guard epoch == currentEpoch else { return }
            journal.record("v2-credentials", "installation-retry-on-next-dial")
        }
    }

    static func credentials(_ cache: V2CachedState) -> [IrxRelayCredential] {
        cache.relayCredentials.map { IrxRelayCredential(relayURL: $0.relayURL, token: $0.token,
            expiresAt: Date(timeIntervalSince1970: Double($0.expiresAt)),
            refreshAfter: Date(timeIntervalSince1970: Double($0.refreshAfter))) }
    }

    func recordEndpointReady(cached: Bool) {
        journal.record("v2-lifecycle", "endpoint-ready", ["cached": String(cached),
            "launchMs": String(Int(Date().timeIntervalSince(launchTime) * 1000))])
    }

    /// Retains healthy IROH sessions while the operating system suspends this process.
    public func didEnterBackground() async {
        applicationActive = false
        activityGeneration &+= 1
        let generation = activityGeneration
        backgroundTime = Date()
        journal.record("v2-lifecycle", "background", ["admittedSessions": String(admittedSessionCount)])
        for engine in Array(enginesByPeer.values) {
            guard generation == activityGeneration else { return }
            await engine.setApplicationActive(false)
        }
    }

    /// Resumes independent peer liveness and backend work without serializing either behind the other.
    public func didBecomeActive() async {
        applicationActive = true
        activityGeneration &+= 1
        let generation = activityGeneration
        journal.record("v2-lifecycle", "foreground", ["backgroundMs": backgroundTime.map {
            String(Int(Date().timeIntervalSince($0) * 1000)) } ?? "0", "admittedSessions": String(admittedSessionCount)])
        backgroundTime = nil
        // Backend renewal starts before peer probes; neither waits for the other.
        foregroundTask?.cancel()
        let service = control
        foregroundTask = Task { await service?.foreground() }
        for engine in Array(enginesByPeer.values) {
            guard generation == activityGeneration else { return }
            await engine.setApplicationActive(true)
            guard generation == activityGeneration else { return }
            await engine.foregroundKick()
        }
    }

    /// Cancels this scope without touching Stack authentication or its keychain entries.
    public func handleSignOut(ifCurrent captured: AuthenticatedTeamScope?) async {
        guard activeScope == captured else { return }
        epoch &+= 1
        activeScope = nil
        await clearCurrentRuntime()
    }

    func clearCurrentRuntime() async {
        provisionTask?.cancel(); provisionTask = nil
        controlTask?.cancel(); controlTask = nil
        foregroundTask?.cancel(); foregroundTask = nil
        endpointWarmupTask?.cancel(); endpointWarmupTask = nil
        let oldControl = control
        let oldSupervisor = endpointSupervisor
        let oldDirectSupervisor = directEndpointSupervisor
        let oldEngines = Array(enginesByPeer.values)
        control = nil; endpointSupervisor = nil; directEndpointSupervisor = nil; identity = nil; cache = nil
        enginesByPeer.removeAll(); dialIntentByPeer.removeAll(); activeDialIntentByPeer.removeAll()
        expectedDeviceIDByPeer.removeAll(); controlLaneClaims.removeAll(); claimedEventSessions.removeAll()
        publish()
        await oldControl?.stop()
        for engine in oldEngines { await engine.stop() }
        await oldSupervisor?.deactivate()
        await oldDirectSupervisor?.deactivate()
    }
}
