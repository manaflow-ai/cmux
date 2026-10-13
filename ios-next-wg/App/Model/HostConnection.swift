import CmuxMobileSSH
import CmuxWireGuard
import CmuxWireGuardPairing
import Foundation
import Observation

/// One paired Mac: the WireGuard link, the cmux-tui control connection over
/// it, and the Mac's workspaces mirrored from tree events.
@MainActor @Observable
final class HostConnection: Identifiable {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    private(set) var host: PairedHost
    private(set) var phase: Phase = .idle
    private(set) var workspaces: [CmuxTUIWorkspace] = []
    private(set) var endpoint: String?
    private(set) var control: CmuxTUIControl?

    nonisolated var id: String { hostID }
    nonisolated let hostID: String

    @ObservationIgnored private let privateKey: WireGuardKey
    @ObservationIgnored private var link: PairedHostLink?
    @ObservationIgnored private var subscription: Task<Void, Never>?
    @ObservationIgnored private var connecting: Task<Void, Never>?
    /// Bumped by every connect and disconnect; a task whose generation is
    /// stale changes nothing and closes what it opened.
    @ObservationIgnored private var generation = 0
    /// Called when the Mac answered on a different endpoint, to persist it.
    @ObservationIgnored var onEndpointLearned: ((PairedHost) -> Void)?

    init(host: PairedHost, privateKey: WireGuardKey) {
        self.host = host
        hostID = host.hostID
        self.privateKey = privateKey
    }

    var terminals: [CmuxTUITerminal] { workspaces.flatMap(\.terminals) }

    /// Connects unless already connected or connecting.
    func connect() {
        guard connecting == nil, phase != .connected else { return }
        phase = .connecting
        generation += 1
        let current = generation
        connecting = Task { [weak self] in
            await self?.establish(current)
            if self?.generation == current { self?.connecting = nil }
        }
    }

    private func establish(_ current: Int) async {
        do {
            let link = try self.link ?? PairedHostLink(host: host, privateKey: privateKey)
            self.link = link
            let stream = try await link.connect(port: OverlayPlan().daemonPort)
            guard generation == current else { return stream.close() }
            let control = try await CmuxTUIControl.open(carrier: TunnelCarrier(stream: stream), session: nil,
                                                        clientName: "cmux-next-ios", handshakeTimeout: .seconds(10))
            guard generation == current else { return await control.close() }
            self.control = control
            endpoint = link.currentEndpoint
            if let endpoint, endpoint != host.lastGoodEndpoint {
                host.lastGoodEndpoint = endpoint
                onEndpointLearned?(host)
            }
            let list = try await control.listWorkspaces()
            guard generation == current else { return }
            workspaces = list
            phase = .connected
            watchTree(control)
        } catch let error as PairingError {
            if generation == current { phase = .failed(error.localizedDescription) }
        } catch {
            if generation == current { phase = .failed(Self.describe(error)) }
        }
    }

    private func watchTree(_ control: CmuxTUIControl) {
        subscription?.cancel()
        subscription = Task { [weak self] in
            guard let events = try? await control.subscribe() else { return }
            for await event in events {
                guard let self else { return }
                switch event {
                case .treeChanged, .titleChanged, .surfaceExited, .empty, .overflow:
                    await self.refresh()
                case .daemonShutdown:
                    self.dropControl(reason: String(localized: "cmux on your Mac quit."))
                    return
                default:
                    break
                }
            }
            // The stream ended: the tunnel or the Mac went away.
            self?.dropControl(reason: nil)
        }
    }

    func refresh() async {
        guard let control else { return }
        if let list = try? await control.listWorkspaces() { workspaces = list }
    }

    private func dropControl(reason: String?) {
        guard control != nil else { return }
        control = nil
        subscription?.cancel()
        subscription = nil
        phase = reason.map { .failed($0) } ?? .idle
    }

    /// Back from the background or on a new network: reconnect.
    func networkChanged() {
        link?.networkChanged()
        if phase != .connected {
            phase = .idle
            connect()
        }
    }

    /// Closes the daemon lane, then the tunnel, so the Mac sees the lane end
    /// (a FIN through the tunnel) instead of a half-open connection.
    @discardableResult
    func disconnect() -> Task<Void, Never> {
        generation += 1
        connecting?.cancel()
        connecting = nil
        subscription?.cancel()
        subscription = nil
        let control = control
        let link = link
        self.control = nil
        self.link = nil
        phase = .idle
        return Task {
            await control?.close()
            link?.close()
        }
    }

    /// A new workspace with one terminal sized for the phone.
    func newTerminal(cols: Int, rows: Int) async throws -> Int? {
        guard let control else { return nil }
        let created = try await control.createWorkspace(name: nil, cols: cols, rows: rows)
        await refresh()
        return created.terminal?.surface
    }

    func close(_ terminal: CmuxTUITerminal) async {
        guard let control, let resource = terminal.resourceID ?? terminal.terminalID else { return }
        try? await control.closeTerminal(resourceID: resource)
        await refresh()
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        return String(describing: error)
    }
}
