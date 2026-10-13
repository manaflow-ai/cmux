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
        connecting = Task { [weak self] in
            await self?.establish()
            self?.connecting = nil
        }
    }

    private func establish() async {
        do {
            let link = try self.link ?? PairedHostLink(host: host, privateKey: privateKey)
            self.link = link
            let stream = try await link.connect(port: OverlayPlan().daemonPort)
            let control = try await CmuxTUIControl.open(carrier: TunnelCarrier(stream: stream), session: nil,
                                                        clientName: "cmux-next-ios", handshakeTimeout: .seconds(10))
            self.control = control
            endpoint = link.currentEndpoint
            if let endpoint, endpoint != host.lastGoodEndpoint {
                host.lastGoodEndpoint = endpoint
                onEndpointLearned?(host)
            }
            workspaces = try await control.listWorkspaces()
            phase = .connected
            watchTree(control)
        } catch let error as PairingError {
            phase = .failed(error.localizedDescription)
        } catch {
            phase = .failed(Self.describe(error))
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

    func disconnect() {
        connecting?.cancel()
        connecting = nil
        subscription?.cancel()
        subscription = nil
        let control = control
        self.control = nil
        Task { await control?.close() }
        link?.close()
        link = nil
        phase = .idle
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
