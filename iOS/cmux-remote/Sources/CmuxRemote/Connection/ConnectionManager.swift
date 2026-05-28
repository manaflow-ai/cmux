import Foundation
import Combine
import SwiftUI
import CmuxKit
import Logging
import UserNotifications

struct PendingHostKeyTrust: Identifiable, Equatable {
    let id = UUID()
    let hostID: UUID
    let label: String
    let username: String
    let hostname: String
    let port: Int
    let fingerprint: String
}

enum RemoteNotificationUserInfo {
    static func stuckSurface(
        surfaceID: SurfaceID,
        workspaceID: WorkspaceID?,
        hostID: UUID? = nil
    ) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            "kind": "stuck_surface",
            "surface_id": surfaceID.raw
        ]
        if let workspaceID {
            userInfo["workspace_id"] = workspaceID.raw
        }
        if let hostID {
            userInfo["host_id"] = hostID.uuidString
        }
        return userInfo
    }
}

/// One per app: owns the active transport + client + reactor + state. Manages
/// foreground/background transitions and re-anchors the cursor through the
/// `ResumeJournal` so reconnects skip already-processed events.
@MainActor
final class ConnectionManager: ObservableObject {
    static let shared = ConnectionManager()

    @Published private(set) var snapshot: ServerState.Snapshot
    @Published private(set) var lastError: String?
    @Published private(set) var activeHostID: UUID?
    @Published private(set) var pendingHostKeyTrust: PendingHostKeyTrust?

    private let log = CmuxLog.make("connection.manager")
    private let resumeJournal: ResumeJournal
    private var client: CMUXClient?
    private var transport: CitadelSSHTransport?
    private var reactor: EventReactor?
    private var remoteDecisionResolutionSupported = false
    private var connectionGeneration = 0
    private var snapshotConsumerTask: Task<Void, Never>?
    private var resumeJournalTask: Task<Void, Never>?
    private var pendingHostKeyContinuation: CheckedContinuation<Bool, Never>?

    private weak var notificationsBridge: NotificationCenterBridge?
    private weak var liveActivity: CMUXLiveActivityController?

    private init() {
        let directory: URL
        if let appGroup = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.cmuxterm.remote"
        ) {
            directory = appGroup.appendingPathComponent("cmux-remote", isDirectory: true)
        } else {
            directory = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("cmux-remote", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.resumeJournal = ResumeJournal(directory: directory)
        let state = ServerState()
        self.state = state
        self.snapshot = ServerState.Snapshot(
            generation: 0,
            connectionPhase: .disconnected(lastError: nil),
            windows: [:], workspaces: [:], panes: [:], surfaces: [:], notifications: [:],
            focusedWorkspaceID: nil, focusedPaneID: nil, focusedSurfaceID: nil,
            cursor: CmuxEventCursor()
        )
    }

    let state: ServerState

    func bind(
        notifications: NotificationCenterBridge,
        liveActivity: CMUXLiveActivityController
    ) async {
        self.notificationsBridge = notifications
        self.liveActivity = liveActivity
        // Kick off the snapshot consumer that bridges actor state → UI.
        snapshotConsumerTask?.cancel()
        snapshotConsumerTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in await self.state.subscribe() {
                await MainActor.run {
                    self.snapshot = snapshot
                    self.notificationsBridge?.applySnapshot(snapshot)
                    self.liveActivity?.applySnapshot(snapshot)
                }
            }
        }
    }

    func connect(to host: CmuxHost) async {
        connectionGeneration += 1
        let generation = connectionGeneration
        activeHostID = host.id
        await tearDown(invalidateConnection: false)
        guard isCurrentConnection(generation: generation, hostID: host.id) else { return }
        await state.resetForHost(host.id)
        do {
            var trustedHost = host
            if trustedHost.serverFingerprintPin == nil {
                try await preflightHostKeyTrust(for: trustedHost)
                guard isCurrentConnection(generation: generation, hostID: host.id) else { return }
                guard let refreshed = HostStore.shared.hosts.first(where: { $0.id == host.id }),
                      refreshed.serverFingerprintPin != nil else {
                    throw CmuxError.transport("Host key was not trusted.", underlying: nil)
                }
                trustedHost = refreshed
            }
            let credential = try await CmuxCredentialStore.shared.resolve(
                host: trustedHost,
                reason: L10n.format(
                    "auth.sign_in.reason",
                    defaultValue: "Sign in to cmux on %@",
                    trustedHost.label
                )
            )
            guard isCurrentConnection(generation: generation, hostID: host.id) else { return }
            guard let pin = trustedHost.serverFingerprintPin else {
                throw CmuxError.transport("Host key was not trusted.", underlying: nil)
            }
            let transport = try CitadelSSHTransport(
                host: trustedHost.hostname,
                port: trustedHost.port,
                username: trustedHost.username,
                credential: credential,
                hostKeyPolicy: .pinFingerprintSHA256(pin),
                connectTimeoutSeconds: 60
            )
            let client = CMUXClient(transport: transport, cmuxBinaryPath: trustedHost.cmuxBinaryPath)
            let capabilities = try await client.capabilities()
            guard isCurrentConnection(generation: generation, hostID: host.id) else {
                await transport.close()
                return
            }
            let supportsRemoteDecisionResolution = capabilities.supportsRemoteDecisionResolution
            if !supportsRemoteDecisionResolution {
                log.warning("connected cmux does not advertise item-bound feed reply capabilities; remote decisions disabled", metadata: [
                    "features": .string(capabilities.supportedFeatures.joined(separator: ","))
                ])
            }
            let trustedHostID = trustedHost.id
            let resumed = await resumeJournal.cursor(for: trustedHostID)
            guard isCurrentConnection(generation: generation, hostID: host.id) else {
                await transport.close()
                return
            }
            await state.setPhase(.connecting)
            // Pre-seed the cursor so the very first events.stream call resumes.
            await applyCursor(resumed)
            guard isCurrentConnection(generation: generation, hostID: host.id) else {
                await transport.close()
                return
            }
            let afkPolicy = AFKPolicyStore.shared.policy
            let stuckDuration = Duration.seconds(Int64(max(60, afkPolicy.watchdogStuckMinutes * 60)))
            let watchdog = AgentWatchdog(configuration: .init(
                stuckThreshold: stuckDuration,
                pollInterval: .seconds(60),
                onStuckSurface: { surfaceID, workspaceID in
                    await ConnectionManager.shared.surfaceStuck(
                        surfaceID: surfaceID,
                        workspaceID: workspaceID,
                        hostID: trustedHostID
                    )
                }
            ))
            let reactor = EventReactor(
                client: client,
                state: state,
                configuration: .init(
                    hostID: trustedHostID,
                    onAgentDecision: { decision in
                        if supportsRemoteDecisionResolution {
                            try await NotificationCenterBridge.shared.observeAgentDecision(decision.scoped(to: trustedHostID))
                        } else {
                            await NotificationCenterBridge.shared.postDecisionResolutionUnsupported(decisionID: decision.id)
                        }
                    },
                    onAgentDecisionResolved: { id in
                        await NotificationCenterBridge.shared.clearAgentDecision(
                            decisionID: id,
                            hostID: trustedHostID
                        )
                    },
                    watchdog: watchdog
                )
            )
            await reactor.start()
            guard isCurrentConnection(generation: generation, hostID: host.id) else {
                await reactor.requestStop()
                await transport.close()
                await reactor.stop()
                return
            }
            self.transport = transport
            self.client = client
            self.reactor = reactor
            self.remoteDecisionResolutionSupported = supportsRemoteDecisionResolution
            // Drain cursor updates into the resume journal. Re-create on
            // every connect so the journal task is bound to the active
            // host id; old tasks (for prior hosts) are cancelled in
            // tearDown().
            resumeJournalTask?.cancel()
            resumeJournalTask = Task { [weak self] in
                guard let self else { return }
                for await snapshot in await self.state.subscribe() {
                    await self.resumeJournal.record(hostID: trustedHost.id, cursor: snapshot.cursor)
                }
            }
        } catch {
            guard isCurrentConnection(generation: generation, hostID: host.id) else { return }
            self.lastError = error.localizedDescription
            log.error("connect failed: \(error.localizedDescription)")
            await state.setPhase(.disconnected(lastError: error.localizedDescription))
        }
    }

    private func preflightHostKeyTrust(for host: CmuxHost) async throws {
        let transport = try CitadelSSHTransport(
            host: host.hostname,
            port: host.port,
            username: host.username,
            hostKeyPolicy: .trustOnFirstUse { fingerprint in
                await ConnectionManager.shared.confirmAndPinHostKey(
                    hostID: host.id,
                    label: host.label,
                    username: host.username,
                    hostname: host.hostname,
                    port: host.port,
                    fingerprint: fingerprint
                )
            },
            connectTimeoutSeconds: 60
        )
        do {
            // The preflight transport intentionally has no real credential.
            // Most SSH servers reject its "none" auth after host-key
            // validation; that post-validation failure is success when the
            // TOFU callback already persisted the fingerprint.
            _ = try await transport.ping()
            await transport.close()
        } catch {
            await transport.close()
            if HostStore.shared.hosts.first(where: { $0.id == host.id })?.serverFingerprintPin != nil {
                return
            }
            throw error
        }
    }

    func confirmAndPinHostKey(
        hostID: UUID,
        label: String,
        username: String,
        hostname: String,
        port: Int,
        fingerprint: String
    ) async -> Bool {
        guard activeHostID == hostID else {
            return false
        }
        if let stored = HostStore.shared.hosts.first(where: { $0.id == hostID }),
           stored.serverFingerprintPin == fingerprint {
            return true
        }

        pendingHostKeyContinuation?.resume(returning: false)
        return await withCheckedContinuation { continuation in
            let pending = PendingHostKeyTrust(
                hostID: hostID,
                label: label,
                username: username,
                hostname: hostname,
                port: port,
                fingerprint: fingerprint
            )
            pendingHostKeyContinuation = continuation
            pendingHostKeyTrust = pending
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(120))
                guard pendingHostKeyTrust?.id == pending.id else {
                    return
                }
                pendingHostKeyTrust = nil
                lastError = L10n.string(
                    "host.key.trust.timeout.error",
                    defaultValue: "Timed out waiting for host-key trust."
                )
                pendingHostKeyContinuation?.resume(returning: false)
                pendingHostKeyContinuation = nil
            }
        }
    }

    func acceptPendingHostKeyTrust() {
        guard let pending = pendingHostKeyTrust else { return }
        guard pending.hostID == activeHostID else {
            pendingHostKeyTrust = nil
            pendingHostKeyContinuation?.resume(returning: false)
            pendingHostKeyContinuation = nil
            return
        }
        let accepted: Bool
        if var stored = HostStore.shared.hosts.first(where: { $0.id == pending.hostID }) {
            stored.serverFingerprintPin = pending.fingerprint
            HostStore.shared.addOrUpdate(stored)
            accepted = true
        } else {
            accepted = false
        }
        pendingHostKeyTrust = nil
        pendingHostKeyContinuation?.resume(returning: accepted)
        pendingHostKeyContinuation = nil
    }

    func rejectPendingHostKeyTrust() {
        guard pendingHostKeyTrust != nil || pendingHostKeyContinuation != nil else { return }
        pendingHostKeyTrust = nil
        lastError = String(
            localized: "host.key.trust.rejected.error",
            defaultValue: "Host key was not trusted."
        )
        pendingHostKeyContinuation?.resume(returning: false)
        pendingHostKeyContinuation = nil
    }

    func disconnect() async {
        await tearDown()
    }

    /// Foreground re-entry: Citadel TCP can't survive backgrounding, so we
    /// rebuild the session and let the reactor's resume cursor skip already-
    /// processed events.
    func handleEnterForeground() async {
        if let id = activeHostID,
           let host = HostStore.shared.hosts.first(where: { $0.id == id }) {
            await connect(to: host)
        } else {
            activeHostID = nil
            lastError = nil
            await state.setPhase(.disconnected(lastError: nil))
            if let host = HostStore.shared.activeHost ?? HostStore.shared.hosts.first {
                await connect(to: host)
            }
        }
    }

    func handleEnterBackground() async {
        await resumeJournal.flush()
        await tearDown()
    }

    private func tearDown(invalidateConnection: Bool = true) async {
        if invalidateConnection {
            connectionGeneration += 1
        }
        // CRITICAL: do NOT cancel `snapshotConsumerTask` here. The consumer
        // is a long-lived subscriber on the ServerState actor and must
        // survive transport reconnects — cancelling it on every connect
        // permanently freezes the UI (regression reported in initial
        // adversarial review). Stop only the transport-coupled actors.
        if pendingHostKeyTrust != nil || pendingHostKeyContinuation != nil {
            pendingHostKeyTrust = nil
            pendingHostKeyContinuation?.resume(returning: false)
            pendingHostKeyContinuation = nil
        }
        let oldReactor = reactor
        let oldTransport = transport
        reactor = nil
        client = nil
        transport = nil
        remoteDecisionResolutionSupported = false
        resumeJournalTask?.cancel()
        resumeJournalTask = nil
        if let oldReactor {
            await oldReactor.requestStop()
        }
        if let oldTransport {
            await oldTransport.close()
        }
        if let oldReactor {
            await oldReactor.stop()
        }
    }

    private func isCurrentConnection(generation: Int, hostID: UUID) -> Bool {
        connectionGeneration == generation && activeHostID == hostID
    }

    private func applyCursor(_ cursor: CmuxEventCursor) async {
        // CRITICAL: do NOT route this through `resetCursor(for:)` — that
        // path was designed for real ack handling, where a boot-id
        // mismatch must wipe the seq. Synthesising a fake ack with an
        // empty boot-id triggered that wipe and dropped the persisted
        // seq, breaking the documented resume contract on every
        // reconnect (regression caught by Codex + Pi). Use the direct
        // `seedCursor` path instead.
        await state.seedCursor(cursor, hostID: activeHostID)
    }

    // MARK: - Public command surface for views

    func client(for action: String) async -> CMUXClient? {
        if client == nil { log.warning("no client for action: \(action)") }
        return client
    }

    func performRemoteAction<T>(
        action: String,
        hostID: UUID? = nil,
        operation: (CMUXClient) async throws -> T
    ) async throws -> T {
        if let client, hostID == nil || hostID == activeHostID {
            return try await operation(client)
        }

        let targetHost: CmuxHost?
        if let hostID {
            targetHost = HostStore.shared.hosts.first(where: { $0.id == hostID })
        } else {
            targetHost = HostStore.shared.activeHost
        }

        guard let host = targetHost else {
            throw CmuxError.unauthenticated(
                hostID == nil
                    ? L10n.string("decision.resolve.no_active_host", defaultValue: "No active cmux host is configured.")
                    : L10n.string("decision.resolve.host_missing", defaultValue: "The cmux host for this action is no longer configured.")
            )
        }
        log.info("using pinned one-shot client for action: \(action)")
        return try await withPinnedOneShotClient(
            host: host,
            reason: L10n.format(
                "auth.notification_action.reason",
                defaultValue: "Run a cmux action on %@",
                host.label
            ),
            operation: operation
        )
    }

    func resolveAgentDecision(
        decisionID: String,
        hostID: UUID? = nil,
        itemID: String? = nil,
        kind: AgentDecision.Kind,
        choiceID: String,
        choiceLabel: String?,
        questionSelections: [AgentDecision.QuestionSelection]? = nil
    ) async throws {
        guard let itemID = itemID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !itemID.isEmpty else {
            throw CmuxError.decoding(
                "refusing to resolve \(kind.rawValue) decision \(decisionID) without item_id",
                underlying: nil
            )
        }
        if let client, hostID == nil || hostID == activeHostID {
            try Self.requireRemoteDecisionResolutionSupport(remoteDecisionResolutionSupported)
            _ = try await client.resolveAgentDecision(
                decisionID: decisionID,
                itemID: itemID,
                kind: kind,
                choiceID: choiceID,
                choiceLabel: choiceLabel,
                questionSelections: questionSelections
            )
            return
        }

        let targetHost: CmuxHost?
        if let hostID {
            targetHost = HostStore.shared.hosts.first(where: { $0.id == hostID })
        } else {
            targetHost = HostStore.shared.activeHost
        }

        guard let host = targetHost else {
            throw CmuxError.unauthenticated(
                hostID == nil
                    ? L10n.string("decision.resolve.no_active_host", defaultValue: "No active cmux host is configured.")
                    : L10n.string("decision.resolve.host_missing", defaultValue: "The cmux host for this decision is no longer configured.")
            )
        }
        try await withPinnedOneShotClient(
            host: host,
            reason: L10n.format(
                "auth.resolve_decision.reason",
                defaultValue: "Resolve a cmux decision on %@",
                host.label
            )
        ) { client in
            let capabilities = try await client.capabilities()
            try Self.requireRemoteDecisionResolutionSupport(capabilities.supportsRemoteDecisionResolution)
            _ = try await client.resolveAgentDecision(
                decisionID: decisionID,
                itemID: itemID,
                kind: kind,
                choiceID: choiceID,
                choiceLabel: choiceLabel,
                questionSelections: questionSelections
            )
        }
    }

    private static func requireRemoteDecisionResolutionSupport(_ supported: Bool) throws {
        guard supported else {
            throw CmuxError.decoding(
                L10n.string(
                    "decision.resolve.unsupported_remote",
                    defaultValue: "This Mac needs a newer cmux before remote decisions can be resolved."
                ),
                underlying: nil
            )
        }
    }

    private func withPinnedOneShotClient<T>(
        host: CmuxHost,
        reason: String,
        operation: (CMUXClient) async throws -> T
    ) async throws -> T {
        guard let pin = host.serverFingerprintPin else {
            throw CmuxError.unauthenticated(
                L10n.string(
                    "decision.resolve.host_key_required",
                    defaultValue: "Open cmux-remote once to trust this host before resolving decisions from the Lock Screen."
                )
            )
        }
        let credential = try await CmuxCredentialStore.shared.resolve(host: host, reason: reason)
        let transport = try CitadelSSHTransport(
            host: host.hostname,
            port: host.port,
            username: host.username,
            credential: credential,
            hostKeyPolicy: .pinFingerprintSHA256(pin),
            connectTimeoutSeconds: 8
        )
        let client = CMUXClient(transport: transport, cmuxBinaryPath: host.cmuxBinaryPath)
        do {
            let result = try await operation(client)
            await transport.close()
            return result
        } catch {
            await transport.close()
            throw error
        }
    }

    // MARK: - Watchdog hook

    private func surfaceStuck(surfaceID: SurfaceID, workspaceID: WorkspaceID?, hostID: UUID?) {
        guard AFKPolicyStore.shared.policy.notifyOnStuck else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.string("notifications.stuck.title", defaultValue: "Agent looks stuck")
        content.body = L10n.string(
            "notifications.stuck.generic_body",
            defaultValue: "No new output in a while. Open cmux-remote to view details."
        )
        content.categoryIdentifier = NotificationCategories.stuckCategory
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = workspaceID.map { "workspace:\($0.raw)" } ?? "stuck"
        content.userInfo = RemoteNotificationUserInfo.stuckSurface(
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            hostID: hostID
        )
        let identifierScope = hostID?.uuidString ?? "unbound"
        let request = UNNotificationRequest(
            identifier: "stuck:\(identifierScope):\(surfaceID.raw)",
            content: content,
            trigger: nil
        )
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }
}
