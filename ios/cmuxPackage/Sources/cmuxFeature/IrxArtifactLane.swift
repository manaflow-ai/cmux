import CmuxIrxTransport
import CmuxMobileRPC
import Foundation

/// Artifact lane over irx: bounded reads down, no upstream bytes.
struct IrxArtifactLane: MobileArtifactLaneConnection {
    let lane: IrxLaneStream

    func receive(maximumByteCount: Int) async throws -> Data? {
        try await lane.reader.readRaw(maximumByteCount: maximumByteCount)
    }

    func close() async {
        await lane.close()
    }
}


/// Browser tunnel lane over irx: raw TCP bytes both ways.
struct IrxTunnelLaneConnection: MobileTunnelLaneConnection {
    let lane: IrxLaneStream

    func receive(maximumByteCount: Int) async throws -> Data? {
        try await lane.reader.readRaw(maximumByteCount: maximumByteCount)
    }

    func send(_ data: Data) async throws {
        try await lane.writer.write(data)
    }

    func finishSending() async {
        await lane.writer.finish()
    }

    func close() async {
        await lane.abort()
    }
}

extension IrxTunnelOpenError {
    var mobileFailure: MobileTunnelOpenFailure {
        switch status {
        case .connected, .failed: .unavailable
        case .denied: .denied
        case .refused: .refused
        case .hostUnreachable: .hostUnreachable
        case .networkUnreachable: .networkUnreachable
        case .timedOut: .timedOut
        case .unresolved: .unresolved
        case .busy: .busy
        }
    }
}
