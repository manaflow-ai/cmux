import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud port discovery state")
struct CloudPortDiscoveryStateTests {
    @Test("A successful scan records no-service and loopback-only reasons")
    func portScanReasons() {
        let noService = CmuxTuiSurfaceProvider.portScan(
            from: VMExecResult(exitCode: 0, stdout: "State Recv-Q Send-Q Local Address:Port Peer Address:Port\n", stderr: ""),
            privateAddress: "10.0.0.7"
        )
        #expect(noService?.emptyReason == .noListeningService)
        let loopback = CmuxTuiSurfaceProvider.portScan(
            from: VMExecResult(
                exitCode: 0,
                stdout: "State Recv-Q Send-Q Local Address:Port Peer Address:Port\nLISTEN 0 128 127.0.0.1:8000 0.0.0.0:*\n",
                stderr: ""
            ),
            privateAddress: "10.0.0.7"
        )
        #expect(loopback?.emptyReason == .loopbackOnly)
        #expect(loopback?.ports == [])
        let missingAddress = CmuxTuiSurfaceProvider.portScan(
            from: VMExecResult(
                exitCode: 0,
                stdout: "State Recv-Q Send-Q Local Address:Port Peer Address:Port\nLISTEN 0 128 0.0.0.0:8000 0.0.0.0:*\n",
                stderr: ""
            ),
            privateAddress: nil
        )
        #expect(missingAddress?.ports == [8000])
        #expect(missingAddress?.emptyReason == nil)
    }
}
