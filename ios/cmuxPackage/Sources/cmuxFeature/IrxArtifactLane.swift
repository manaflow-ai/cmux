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

