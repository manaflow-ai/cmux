#if DEBUG
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Next transport pairing requires explicit authority")
struct NextTransportPairAuthorizationTests {
    @Test func absentAuthorityFailsClosed() {
        #expect(!TerminalController.nextTransportPairRequesterIsBound(
            deviceID: "phone", deviceKey: Data(repeating: 1, count: 32),
            appIdentity: "dev.cmux.next.ios", proofBase64: nil, authorization: nil))
    }

    @Test func explicitLocalSocketCanProvisionOtherAppIdentities() {
        #expect(TerminalController.nextTransportPairRequesterIsBound(
            deviceID: "phone", deviceKey: Data(repeating: 1, count: 32),
            appIdentity: "test.app", proofBase64: nil, authorization: .localControlSocket))
    }

    @Test func networkAuthorityStillRequiresProof() {
        let context = MobileHostRPCExecutionContext(
            connectionID: UUID(), authorization: .stackBearer, artifactTransfers: nil)
        #expect(!TerminalController.nextTransportPairRequesterIsBound(
            deviceID: "phone", deviceKey: Data(repeating: 1, count: 32),
            appIdentity: "dev.cmux.next.ios", proofBase64: nil, authorization: .mobileRPC(context)))
    }
}
#endif
