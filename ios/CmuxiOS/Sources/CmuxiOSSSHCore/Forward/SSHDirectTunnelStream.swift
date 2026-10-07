import CmuxiOSFeatureKit
import CmuxMobileSSH
import Foundation

/// `TunnelStream` over a C9 `direct-tcpip` channel.
struct SSHDirectTunnelStream: TunnelStream {
    let stream: SSHDirectStream

    func read() async throws -> Data? { try await stream.read() }
    func write(_ data: Data) async throws { try await stream.write(data) }
    func finishWriting() async { await stream.finishWriting() }
    func close() async { await stream.close() }
}
