import Foundation
import CmuxNativeLink
import CmuxNativeWire

/// Splices one phone `daemon:<uuid>` channel onto a fresh daemon socket
/// connection. Phone→daemon lines pass `DaemonChannelPolicy`; daemon→phone
/// lines pass unchanged. Either side ending closes both, which makes the
/// daemon drop the phone's leases and streams.
public struct DaemonChannelBridge: Sendable {
    /// Daemon lines may carry a full VT replay (the daemon caps them at 32 MiB).
    public static let maximumDaemonLineBytes = 64 << 20

    public enum EndReason: Equatable, Sendable {
        case phoneClosed
        case daemonClosed
        case daemonUnavailable(String)
        case protocolViolation(String)
    }

    public let socketPath: String?
    public let policy: DaemonChannelPolicy
    public let log: @Sendable (String) -> Void

    public init(socketPath: String?, policy: DaemonChannelPolicy, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.socketPath = socketPath
        self.policy = policy
        self.log = log
    }

    public func run(channel: any LinkChannel) async -> EndReason {
        guard let socketPath else {
            await refuseAll(channel, message: "no cmux daemon socket found on this host")
            return .daemonUnavailable("no socket")
        }
        let daemon: UnixSocketConnection
        do {
            daemon = try UnixSocketConnection.connect(path: socketPath)
        } catch {
            await refuseAll(channel, message: "cmux daemon is not reachable: \(error)")
            return .daemonUnavailable("\(error)")
        }
        let policy = self.policy
        let reason = await withTaskGroup(of: EndReason.self) { group in
            group.addTask {
                for await line in channel.incoming {
                    switch policy.evaluate(line) {
                    case .forward:
                        var out = line
                        out.append(0x0A)
                        do { try await daemon.write(out) } catch { return .daemonClosed }
                    case .refuse(let response):
                        try? await channel.send(response)
                    }
                }
                return .phoneClosed
            }
            group.addTask {
                var splitter = ByteStreamLineSplitter(maximumLineBytes: Self.maximumDaemonLineBytes)
                for await chunk in daemon.chunks {
                    let lines: [Data]
                    do { lines = try splitter.append(chunk) } catch { return .protocolViolation("daemon line too large") }
                    for line in lines {
                        do { try await channel.send(line) } catch { return .phoneClosed }
                    }
                }
                return .daemonClosed
            }
            let first = await group.next() ?? .daemonClosed
            channel.close()
            daemon.close()
            group.cancelAll()
            return first
        }
        log("daemon channel \(channel.label) ended: \(reason)")
        return reason
    }

    /// With no daemon, answer every request with an error and close.
    private func refuseAll(_ channel: any LinkChannel, message: String) async {
        log("daemon channel \(channel.label): \(message)")
        try? await channel.send(DaemonChannelPolicy.errorLine(id: nil, code: "daemon_unavailable", message: message))
        channel.close()
    }
}
