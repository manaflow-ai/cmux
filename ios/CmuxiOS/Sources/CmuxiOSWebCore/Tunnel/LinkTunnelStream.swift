import CmuxiOSFeatureKit
import CmuxMobileLink
import CmuxMobileWire
import Foundation

/// A `TunnelStream` over one opened `tcp.forward` channel: raw-byte records,
/// `fin` for half close, `channel.closed` when the Mac ended both directions.
actor LinkTunnelStream: TunnelStream {
    static let maxRecord = 64 * 1024

    private let channel: MobileChannel
    private var remoteFinished = false

    init(channel: MobileChannel) {
        self.channel = channel
    }

    func read() async throws -> Data? {
        while !remoteFinished {
            switch await channel.receive() {
            case .binary(let data, let flags):
                if flags.contains(.fin) { remoteFinished = true }
                if !data.isEmpty { return data }
            case .json(let value):
                guard case .channelClosed(let closed)? = try? MobileFrame(value: value) else { continue }
                remoteFinished = true
                if let code = closed.code { throw LinkTunnelStreamError.reset(code) }
            case .gap:
                throw LinkTunnelStreamError.lost
            case .closed:
                remoteFinished = true
            }
        }
        return nil
    }

    func write(_ data: Data) async throws {
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: Self.maxRecord, limitedBy: data.endIndex) ?? data.endIndex
            try await channel.send(binary: data[offset..<end])
            offset = end
        }
    }

    func finishWriting() async {
        try? await channel.send(binary: Data(), flags: .fin)
    }

    func close() async {
        await channel.abort()
    }
}
