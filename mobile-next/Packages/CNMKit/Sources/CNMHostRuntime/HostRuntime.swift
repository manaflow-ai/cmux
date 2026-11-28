#if os(macOS)
import CNMBackend
import CNMHost
import CNMTransport
import CNMWebRTC
import Foundation
import Observation

/// The Mac host's lifecycle, shared by the `cnm-host` CLI and the menu bar
/// app: pairing, the saved identity, signaling and accepting phones.
@MainActor
@Observable
public final class HostRuntime {
    public enum Phase: Equatable {
        case idle
        case pairing(code: String)
        /// A phone claimed the code; the Mac's owner must approve this account.
        case approving(code: String, email: String)
        case serving
        case failed(String)
    }

    public struct Identity: Codable, Equatable, Sendable {
        public var hostID: String
        public var hostToken: String
        public var userEmail: String?
        public var name: String

        public init(hostID: String, hostToken: String, userEmail: String?, name: String) {
            self.hostID = hostID
            self.hostToken = hostToken
            self.userEmail = userEmail
            self.name = name
        }
    }

    public private(set) var phase: Phase = .idle
    public private(set) var identity: Identity?
    public private(set) var phones = 0
    public private(set) var signalingUp = false

    public let environment: HostEnvironment
    public let backend: BackendClient
    public var name: String
    public var relayOnly = false
    @ObservationIgnored private let log: @Sendable (String) -> Void
    @ObservationIgnored private var server: HostServer?
    @ObservationIgnored private var signaling: WebSocketSignaling?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pairingTask: Task<Void, Never>?

    public init(environment: HostEnvironment, backend: BackendClient, name: String, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.environment = environment
        self.backend = backend
        self.name = name
        self.log = log
        identity = Self.load(from: environment)
    }

    private var identityURL: URL { environment.supportDirectory.appendingPathComponent("identity.json") }

    private static func load(from environment: HostEnvironment) -> Identity? {
        guard let data = try? Data(contentsOf: environment.supportDirectory.appendingPathComponent("identity.json")) else { return nil }
        return try? JSONDecoder().decode(Identity.self, from: data)
    }

    /// Puts the runtime in a phase without the network (snapshot tests).
    public func showPhaseForSnapshot(_ phase: Phase, identity: Identity? = nil) {
        self.phase = phase
        if let identity { self.identity = identity }
    }

    // MARK: Pairing

    /// Decides whether to give this Mac to the account that claimed the code.
    /// The CLI asks on the terminal; the menu bar app shows Approve/Reject.
    public typealias Approver = @MainActor (_ email: String) async -> Bool

    @ObservationIgnored private var approvalContinuation: CheckedContinuation<Bool, Never>?

    /// The menu bar app's buttons answer the pending approval.
    public func answerApproval(_ approve: Bool) {
        approvalContinuation?.resume(returning: approve)
        approvalContinuation = nil
    }

    /// Waits for `answerApproval`.
    public func approveFromUI(_ email: String) async -> Bool {
        await withCheckedContinuation { approvalContinuation = $0 }
    }

    /// Shows a code and waits until a phone claims it and the Mac's owner
    /// approves that account. `onCode` fires once with the code.
    public func pair(
        onCode: @escaping @MainActor (String) -> Void = { _ in },
        approve: Approver? = nil
    ) async throws -> Identity {
        let start = try await backend.startPairing(hostName: name, platform: "macos", appVersion: HostServer.version)
        phase = .pairing(code: start.code)
        onCode(start.code)
        var answered = false
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(2))
            let poll = try await backend.pollPairing(start)
            switch poll.status {
            case "pending":
                continue
            case "awaiting_approval":
                guard !answered else { continue }
                answered = true
                let email = poll.user?.email ?? "an unknown account"
                phase = .approving(code: start.code, email: email)
                let decider = approve ?? { [weak self] email in await self?.approveFromUI(email) ?? false }
                if await decider(email) {
                    try await backend.approvePairing(start)
                    phase = .pairing(code: start.code)
                } else {
                    try? await backend.rejectPairing(start)
                    throw TransportError("Pairing rejected on this Mac.")
                }
            case "rejected":
                throw TransportError("Pairing rejected.")
            case "claimed":
                guard let hostID = poll.hostID, let token = poll.hostToken else { throw TransportError("Pairing reply is incomplete") }
                let identity = Identity(hostID: hostID, hostToken: token, userEmail: poll.user?.email, name: name)
                let data = try JSONEncoder().encode(identity)
                try data.write(to: identityURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identityURL.path)
                self.identity = identity
                return identity
            default:
                throw TransportError("Pairing \(poll.status).")
            }
        }
        throw CancellationError()
    }

    /// Pairs when needed, then serves; in the app a new code is shown when
    /// the previous one expires.
    public func start() {
        pairingTask?.cancel()
        pairingTask = Task {
            while identity == nil, !Task.isCancelled {
                do {
                    _ = try await pair()
                } catch is CancellationError {
                    return
                } catch {
                    log("pairing: \(error.localizedDescription)")
                    phase = .failed(error.localizedDescription)
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            if let identity { serve(identity) }
        }
    }

    /// Forgets this Mac's pairing here and on the server (waits up to 5 s
    /// for the server so a CLI that exits right after still revokes).
    public func unpair() async {
        if let token = identity?.hostToken {
            let backend = backend
            let request = Task { try? await backend.unpairHost(token: token) }
            let timeout = Task { try? await Task.sleep(for: .seconds(5)); request.cancel() }
            _ = await request.value
            timeout.cancel()
        }
        stop()
        try? FileManager.default.removeItem(at: identityURL)
        identity = nil
        phase = .idle
    }

    public func stop() {
        pairingTask?.cancel()
        for task in tasks { task.cancel() }
        tasks = []
        signaling?.close()
        signaling = nil
        server?.shutdown()
        server = nil
        signalingUp = false
        phones = 0
        if case .serving = phase { phase = .idle }
    }

    // MARK: Serving

    private func serve(_ identity: Identity) {
        let token = identity.hostToken
        let server = HostServer(hostName: identity.name, hostID: identity.hostID, environment: environment, log: log)
        let signaling = WebSocketSignaling(baseURL: backend.baseURL, peerID: "host-" + identity.hostID, tokenProvider: { token })
        let hub = SignalHub(channel: signaling)
        let backend = backend
        let acceptor = WebRTCAcceptor(hub: hub, options: WebRTCOptions(
            iceServers: {
                let servers = (try? await backend.iceServers(token: token)) ?? []
                let mapped = servers.map { ICEServer(urls: $0.urls, username: $0.username, credential: $0.credential) }
                return mapped.isEmpty ? [.cloudflareSTUN] : mapped
            },
            relayOnly: relayOnly
        ))
        self.server = server
        self.signaling = signaling
        phase = .serving
        log("serving \(identity.name) (\(identity.hostID)) for \(identity.userEmail ?? "?") via \(backend.baseURL.host ?? "")")
        tasks.append(Task { [weak self] in
            for await event in hub.subscribe() {
                switch event {
                case .welcome(let me, let peers):
                    self?.log("signaling up as \(me.id); \(peers.count) peers")
                    self?.signalingUp = true
                case .closed(let reason):
                    self?.log("signaling closed: \(reason ?? "")")
                    self?.signalingUp = false
                    // A host token never expires: unauthorized means revoked.
                    if reason == "revoked" || reason == "unauthorized" {
                        self?.log("this Mac was removed from the account; pairing again")
                        Task {
                            await self?.unpair()
                            self?.start()
                        }
                    }
                default:
                    break
                }
            }
        })
        tasks.append(Task { [weak self] in
            for await link in acceptor.incoming {
                server.serve(link)
                self?.phones = server.connectedPeerCount
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.phones = server.connectedPeerCount
            }
        })
    }
}
#endif
