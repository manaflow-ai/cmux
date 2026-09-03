internal import Foundation
import CmuxLiteProtocol
import CmuxLiteSession

/// Test-only construction of the deterministic host half of a session.
struct FakeMacHost {
    let owner: SessionOwner

    init(
        stream: any ByteStream,
        codec: FrameCodec,
        sessionID: String = "session-1",
        nonce: String = "host-nonce"
    ) {
        owner = SessionOwner(
            configuration: .server(
                welcome: .init(sessionID: sessionID, nonce: nonce)
            ),
            stream: stream,
            codec: codec
        )
    }
}
