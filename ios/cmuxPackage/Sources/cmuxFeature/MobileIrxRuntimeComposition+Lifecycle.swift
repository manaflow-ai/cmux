public import CmuxAuthRuntime
import CmuxIrxTransport
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

extension MobileIrxRuntimeComposition {
    private static let endpointWarmupRetryLimit = 5

    private struct DetachedRuntime: Sendable {
        let control: V2ControlService?
        let endpointSupervisor: IrxEndpointSupervisor?
        let directEndpointSupervisor: IrxEndpointSupervisor?
        let engines: [IrxPeerEngine]
    }

    /// Observes account/team authority for the lifetime of the app.
    public func configure(auth: AuthCoordinator) async {
        guard authTask == nil else { return }
        self.auth = auth
        journal.record("v2-lifecycle", "launch")
        // Cached v2 state is local, encrypted, and scoped to the persisted
        // account/team tuple. Warm it immediately while Stack restores the
        // session. This path can render the cached directory and start IROH,
        // but it cannot issue or authorize any control-plane mutation.
        let startupEpoch = epoch
        cachedWarmupTask = Task { [weak self, weak auth] in
            guard let self, let auth else { return }
            await self.warmCachedRuntime(auth: auth, expectedEpoch: startupEpoch)
        }
        authTask = Task { [weak self, weak auth] in
            guard let auth else { return }
            await auth.awaitBootstrapped()
            for await scope in await auth.authenticatedTeamScopes() {
                guard !Task.isCancelled else { return }
                await self?.activate(scope)
            }
        }
    }

    private func warmCachedRuntime(auth: AuthCoordinator, expectedEpoch: UInt64) async {
        guard let cachedIdentity = await auth.cachedTeamIdentity else { return }
        do {
            let deviceID = try await installation.deviceID()
            let tuple = V2Identity(
                appNamespace: configuration.appNamespace,
                buildTag: tag,
                deviceID: deviceID,
                environment: configuration.environment,
                projectID: configuration.projectID,
                teamID: cachedIdentity.teamID,
                userID: cachedIdentity.accountID
            )
            let key = try await installation.key(identity: tuple)
            let stateStore = V2FileStateStore(
                rootDirectory: configuration.stateDirectory,
                fileManager: FileManager(),
                identityKey: key
            )
            let restored = try await stateStore.load(identity: tuple)
            guard epoch == expectedEpoch,
                  await auth.cachedTeamIdentity == cachedIdentity,
                  let restored,
                  !restored.authorityRevoked else { return }

            let identity = IrxIdentity(
                privateKeyData: key.secretKey,
                deviceID: deviceID,
                appInstanceID: key.endpointID
            )
            let supervisor = IrxEndpointSupervisor(
                configuration: IrxEndpointConfiguration(
                    identity: identity,
                    pathMode: forceRelayOnly ? .relayOnly : .automatic,
                    initialRemoteBiStreams: 0,
                    initialRemoteUniStreams: 0
                ),
                journal: journal,
                diagnosticLog: diagnosticLog
            )
            guard epoch == expectedEpoch,
                  await auth.cachedTeamIdentity == cachedIdentity else { return }
            preparedCachedRuntime = PreparedCachedRuntime(
                identity: identity,
                key: key,
                tuple: tuple,
                stateStore: stateStore,
                restored: restored,
                supervisor: supervisor
            )
            cache = restored
            await projectCachedDirectoryForUI(restored.directory, identity: cachedIdentity, auth: auth)
            guard epoch == expectedEpoch,
                  await auth.cachedTeamIdentity == cachedIdentity else { return }
            let credentials = Self.credentials(restored)
            if credentials.contains(where: { $0.isUsable(at: Date()) }) {
                endpointWarmupEpoch = expectedEpoch
                endpointWarmupTask = makeEndpointWarmupTask(
                    supervisor: supervisor,
                    credentials: credentials,
                    expectedEpoch: expectedEpoch,
                    cached: true,
                    scope: nil
                )
            }
            journal.record("v2-lifecycle", "cached-warm-start", [
                "directory": String(restored.directory?.devices.count ?? 0),
                "hasCredentials": String(!credentials.isEmpty)
            ])
            publish()
        } catch {
            journal.record("v2-lifecycle", "cached-warm-start-unavailable")
        }
    }

    func activate(_ scope: AuthenticatedTeamScope?) async {
        let hasRuntimeToClear = scope == nil && (
            cachedWarmupTask != nil
                || preparedCachedRuntime != nil
                || endpointWarmupTask != nil
                || endpointSupervisor != nil
                || control != nil
                || cache != nil
        )
        guard scope != activeScope || hasRuntimeToClear else { return }
        epoch &+= 1
        let currentEpoch = epoch
        activeScope = scope
        let preservePrepared = scope.map { candidate in
            preparedCachedRuntime?.tuple.userID == candidate.session.accountID
                && preparedCachedRuntime?.tuple.teamID == candidate.teamID
        } ?? false
        let detached = await detachCurrentRuntime(preservePrepared: preservePrepared)
        scheduleShutdown(of: detached)
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
        let tuple = V2Identity(appNamespace: configuration.appNamespace, buildTag: tag,
            deviceID: try await installation.deviceID(), environment: configuration.environment,
            projectID: configuration.projectID, teamID: scope.teamID, userID: scope.session.accountID)
        let prepared = preparedCachedRuntime?.tuple == tuple ? preparedCachedRuntime : nil
        preparedCachedRuntime = nil
        let deviceID = tuple.deviceID
        let key: V2IdentityKey
        let stateStore: V2FileStateStore
        let restored: V2CachedState?
        let supervisor: IrxEndpointSupervisor
        let identity: IrxIdentity
        if let prepared {
            key = prepared.key
            stateStore = prepared.stateStore
            restored = prepared.restored
            supervisor = prepared.supervisor
            identity = prepared.identity
        } else {
            key = try await installation.key(identity: tuple)
            stateStore = V2FileStateStore(rootDirectory: configuration.stateDirectory,
                fileManager: FileManager(), identityKey: key)
            // A corrupt disposable cache is recoverable through a signed v2 setup;
            // the identity seed and Stack authentication are never erased.
            restored = try? await stateStore.load(identity: tuple)
            identity = IrxIdentity(privateKeyData: key.secretKey, deviceID: deviceID, appInstanceID: key.endpointID)
            supervisor = IrxEndpointSupervisor(configuration: IrxEndpointConfiguration(
                identity: identity, pathMode: forceRelayOnly ? .relayOnly : .automatic,
                initialRemoteBiStreams: 0, initialRemoteUniStreams: 0), journal: journal,
                diagnosticLog: diagnosticLog)
        }
        try await assertScope(scope, epoch: currentEpoch)
        self.identity = identity
        endpointSupervisor = supervisor
        cache = restored ?? V2CachedState(identity: tuple)
        publish()
        if let directory = restored?.directory, restored?.authorityRevoked == false {
            await projectDirectoryForUI(directory, scope: scope)
            try await assertScope(scope, epoch: currentEpoch)
        }
        // Cached IROH binding never waits for a backend handshake or Stack refresh.
        if endpointWarmupEpoch != currentEpoch {
            endpointWarmupTask?.cancel()
            endpointWarmupTask = nil
            endpointWarmupEpoch = nil
        }
        if endpointWarmupTask == nil, let restored, !restored.authorityRevoked {
            let credentials = Self.credentials(restored)
            if credentials.contains(where: { $0.isUsable(at: Date()) }) {
                endpointWarmupEpoch = currentEpoch
                endpointWarmupTask = makeEndpointWarmupTask(
                    supervisor: supervisor,
                    credentials: credentials,
                    expectedEpoch: currentEpoch,
                    cached: true,
                    scope: scope
                )
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
            },
            journal: journal)
        let service = V2ControlService(configuration: try V2ControlConfiguration(
            baseURL: configuration.baseURL, device: device), dependencies: dependencies, store: stateStore)
        try await assertScope(scope, epoch: currentEpoch)
        control = service
        controlTask = Task { [weak self] in
            for await snapshot in await service.events() {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.apply(snapshot, scope: scope, epoch: currentEpoch)
                await service.acknowledgeApplied(sequence: snapshot.sequence)
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
        let status = String(describing: snapshot.status)
        let failure = snapshot.failure?.diagnosticCode ?? "none"
        let state = status + ":" + failure
        if state != lastLoggedControlState {
            lastLoggedControlState = state
            journal.record("v2-control", "state-changed", ["status": status, "failure": failure,
                "environment": configuration.environment, "host": configuration.baseURL.host ?? "",
                "project": configuration.projectID])
        }
        // The service publishes its empty initial state before reading the same cache.
        guard snapshot.cache.device != nil || cache?.device == nil || snapshot.cache.authorityRevoked else { return }
        let previousCredentials = cache?.relayCredentials
        let previousRelays = Dictionary((cache?.directory?.devices ?? []).map {
            ($0.descriptor.endpointID, $0.descriptor.metadata.relayURLs)
        }, uniquingKeysWith: { _, latest in latest })
        cache = snapshot.cache
        lastFailure = snapshot.failure.map { String(describing: $0) }
        publish()
        if snapshot.cache.authorityRevoked {
            await MainActor.run { self.macListAuthState.clear() }
            guard (try? await assertScope(scope, epoch: currentEpoch)) != nil else { return }
            let engines = Array(enginesByPeer.values)
            let supervisor = endpointSupervisor
            let directSupervisor = directEndpointSupervisor
            endpointWarmupTask?.cancel()
            endpointWarmupTask = nil
            endpointWarmupEpoch = nil
            for engine in engines { await engine.stop(code: .revoked) }
            await supervisor?.deactivate()
            await directSupervisor?.deactivate()
            guard (try? await assertScope(scope, epoch: currentEpoch)) != nil else { return }
            journal.record("v2-lifecycle", "authority-revoked")
            return
        }
        if let directory = snapshot.cache.directory {
            await projectDirectoryForUI(directory, scope: scope)
            guard (try? await assertScope(scope, epoch: currentEpoch)) != nil else { return }
            let permitted = Set(directory.devices.filter { !$0.revoked }.map { $0.descriptor.endpointID })
            for (peer, engine) in enginesByPeer where !permitted.contains(peer) {
                await engine.stop(code: .revoked)
            }
            for record in directory.devices where !record.revoked {
                let peer = record.descriptor.endpointID
                if let previous = previousRelays[peer], previous != record.descriptor.metadata.relayURLs {
                    await enginesByPeer[peer]?.relayHintChanged(trigger: "v2-directory-relay")
                }
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

    private static func readyEndpointWithTimeout(
        supervisor: IrxEndpointSupervisor,
        credentials: [IrxRelayCredential]
    ) async throws {
        let operation = Task {
            _ = try await supervisor.readyEndpoint(credentials: credentials)
        }
        do {
            try await RPCTaskTimeout().value(
                operation,
                timeoutNanoseconds: 30_000_000_000
            )
        } catch MobileShellConnectionError.requestTimedOut {
            operation.cancel()
            throw CompositionError.endpointWarmupTimedOut
        } catch {
            operation.cancel()
            throw error
        }
    }

    private func makeEndpointWarmupTask(
        supervisor: IrxEndpointSupervisor,
        credentials: [IrxRelayCredential],
        expectedEpoch: UInt64,
        cached: Bool,
        scope: AuthenticatedTeamScope?
    ) -> Task<Void, Never> {
        Task { [weak self] in
            var delay: TimeInterval = 1
            for attempt in 0..<Self.endpointWarmupRetryLimit where !Task.isCancelled {
                guard let self, await self.epoch == expectedEpoch else { return }
                do {
                    try await Self.readyEndpointWithTimeout(
                        supervisor: supervisor,
                        credentials: credentials
                    )
                    if let scope {
                        try await self.assertScope(scope, epoch: expectedEpoch)
                    }
                    await self.endpointWarmupSucceeded(epoch: expectedEpoch)
                    await self.recordEndpointReady(cached: cached)
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard await self.epoch == expectedEpoch else { return }
                    await self.endpointWarmupFailed(epoch: expectedEpoch)
                    guard attempt + 1 < Self.endpointWarmupRetryLimit else {
                        await self.endpointWarmupExhausted(epoch: expectedEpoch)
                        return
                    }
                    try? await RPCTaskTimeout.continuousClockSleep(
                        nanoseconds: UInt64(delay * 1_000_000_000)
                    )
                    delay = min(delay * 2, 30)
                }
            }
        }
    }

    func endpointWarmupFailed(epoch expectedEpoch: UInt64) {
        guard endpointWarmupEpoch == expectedEpoch else { return }
        lastFailure = "The connection service could not start. It will retry."
        journal.record("v2-lifecycle", "endpoint-warmup-retry")
        publish()
    }

    func endpointWarmupSucceeded(epoch expectedEpoch: UInt64) {
        guard endpointWarmupEpoch == expectedEpoch else { return }
        endpointWarmupTask = nil
        endpointWarmupEpoch = nil
        lastFailure = nil
        publish()
    }

    func endpointWarmupExhausted(epoch expectedEpoch: UInt64) {
        guard endpointWarmupEpoch == expectedEpoch else { return }
        endpointWarmupTask = nil
        endpointWarmupEpoch = nil
        lastFailure = "The connection service is unavailable. It will retry when the app returns to the foreground."
        journal.record("v2-lifecycle", "endpoint-warmup-exhausted")
        publish()
    }

    func recordEndpointReady(cached: Bool) {
        journal.record("v2-lifecycle", "endpoint-ready", ["cached": String(cached),
            "launchMs": String(Int(Date().timeIntervalSince(launchTime) * 1000))])
        publish()
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
        // iroh disables its sleep detection on iOS, so the network may have
        // changed while suspended without iroh noticing; tell it before the
        // peer probes run so they measure fresh paths.
        await notifyNetworkChange()
        guard generation == activityGeneration else { return }
        retryEndpointWarmupIfNeeded()
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

    private func retryEndpointWarmupIfNeeded() {
        guard endpointWarmupTask == nil,
              let supervisor = endpointSupervisor ?? preparedCachedRuntime?.supervisor,
              let cached = cache ?? preparedCachedRuntime?.restored,
              !cached.authorityRevoked else { return }
        let credentials = Self.credentials(cached)
        guard credentials.contains(where: { $0.isUsable(at: Date()) }) else { return }
        let expectedEpoch = epoch
        endpointWarmupEpoch = expectedEpoch
        endpointWarmupTask = makeEndpointWarmupTask(
            supervisor: supervisor,
            credentials: credentials,
            expectedEpoch: expectedEpoch,
            cached: activeScope == nil,
            scope: activeScope
        )
    }

    /// Cancels this scope without touching Stack authentication or its keychain entries.
    public func handleSignOut(ifCurrent captured: AuthenticatedTeamScope?) async {
        guard activeScope == captured else { return }
        epoch &+= 1
        activeScope = nil
        let detached = await detachCurrentRuntime()
        scheduleShutdown(of: detached)
    }

    private func detachCurrentRuntime(preservePrepared: Bool = false) async -> DetachedRuntime {
        provisionTask?.cancel(); provisionTask = nil
        controlTask?.cancel(); controlTask = nil
        foregroundTask?.cancel(); foregroundTask = nil
        if !preservePrepared {
            endpointWarmupTask?.cancel(); endpointWarmupTask = nil; endpointWarmupEpoch = nil
        }
        if !preservePrepared {
            cachedWarmupTask?.cancel(); cachedWarmupTask = nil
        }
        let oldControl = control
        let oldSupervisor = endpointSupervisor ?? (preservePrepared ? nil : preparedCachedRuntime?.supervisor)
        let oldDirectSupervisor = directEndpointSupervisor
        let oldEngines = Array(enginesByPeer.values)
        control = nil; endpointSupervisor = nil; directEndpointSupervisor = nil
        if !preservePrepared {
            identity = nil; cache = nil; preparedCachedRuntime = nil
        }
        lastLoggedControlState = nil
        lastFailure = nil
        enginesByPeer.removeAll(); dialIntentByPeer.removeAll(); activeDialIntentByPeer.removeAll()
        expectedDeviceIDByPeer.removeAll(); controlLaneClaims.removeAll(); claimedEventSessions.removeAll()
        let oldEventLaneHubs = eventLaneHubs.values.map(\.hub)
        eventLaneHubs.removeAll()
        for hub in oldEventLaneHubs { Task { await hub.stop() } }
        publish()
        if !preservePrepared {
            await MainActor.run { self.macListAuthState.clear() }
        }
        return DetachedRuntime(
            control: oldControl,
            endpointSupervisor: oldSupervisor,
            directEndpointSupervisor: oldDirectSupervisor,
            engines: oldEngines
        )
    }

    private func scheduleShutdown(of runtime: DetachedRuntime) {
        Task {
            await runtime.control?.stop()
            for engine in runtime.engines {
                await engine.stop()
            }
            await runtime.endpointSupervisor?.deactivate()
            await runtime.directEndpointSupervisor?.deactivate()
        }
    }

    /// Forwards a platform network change to every live iroh endpoint so
    /// paths that died with the old network are abandoned immediately.
    public func notifyNetworkChange() async {
        let supervisors = [endpointSupervisor, directEndpointSupervisor].compactMap { $0 }
        for supervisor in supervisors {
            await supervisor.notifyNetworkChange()
        }
    }
}
