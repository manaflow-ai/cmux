import CNCore
import CNTransport
import Foundation

/// Short, user-facing description of a `HostConnectionState`, shared by the
/// shell's status pill and Settings > Connection.
public struct ConnectionSummary: Sendable, Hashable {
    public enum Tone: Sendable, Hashable { case good, relayed, pending, bad }

    public var title: String
    public var detail: String?
    public var tone: Tone
    public var symbol: String

    public init(_ state: HostConnectionState) {
        switch state {
        case .idle:
            self.init(title: "Not connected", detail: nil, tone: .bad, symbol: "bolt.horizontal.circle")
        case .connecting:
            self.init(title: "Connecting", detail: nil, tone: .pending, symbol: "bolt.horizontal")
        case .reconnecting(_, let lastError):
            self.init(title: "Reconnecting", detail: lastError, tone: .pending, symbol: "arrow.triangle.2.circlepath")
        case .failed(let message):
            self.init(title: "Offline", detail: message, tone: .bad, symbol: "exclamationmark.triangle")
        case .connected(let path):
            let rtt = path.rttMs.map { "\(Int($0.rounded())) ms" }
            if path.transport == "loopback" {
                self.init(title: "Demo", detail: rtt, tone: .good, symbol: "desktopcomputer")
            } else if path.isRelayed {
                self.init(title: "Relayed via TURN", detail: rtt, tone: .relayed, symbol: "point.3.connected.trianglepath.dotted")
            } else {
                let lan = path.localCandidate == .host && path.remoteCandidate == .host
                self.init(title: lan ? "Direct (LAN)" : "Direct", detail: rtt, tone: .good, symbol: "bolt.horizontal.fill")
            }
        }
    }

    /// Like `init(_:)`, but while not connected a Mac that presence reports
    /// offline reads "<name> is offline" instead of an endless reconnect.
    public init(_ state: HostConnectionState, host: HostRecord?) {
        if !state.isConnected, let host, !host.online {
            self.init(title: "\(host.name) is offline",
                      detail: "cmux reconnects when the Mac is back online.",
                      tone: .bad, symbol: "desktopcomputer")
        } else {
            self.init(state)
        }
    }

    public init(title: String, detail: String?, tone: Tone, symbol: String) {
        self.title = title; self.detail = detail; self.tone = tone; self.symbol = symbol
    }

    /// `Direct · 12 ms`
    public var compact: String { [title, detail].compactMap { $0 }.joined(separator: " · ") }
}
