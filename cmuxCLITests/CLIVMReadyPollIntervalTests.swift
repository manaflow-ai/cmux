import Foundation
import Testing

@testable import cmux_cli

/// `vmReadyPollInterval` lives in the CLI target, so its pure override policy
/// is checked here rather than from the app-hosted `CLIVMTransferTests`,
/// where `CMUXCLI` names the app's routing type instead.
@Suite("cmux vm: ready poll interval")
struct CLIVMReadyPollIntervalTests {
    @Test("Valid overrides are used; missing, malformed or out-of-range ones fall back to 3s",
          arguments: [
              (nil, 3.0), ("0.05", 0.05), ("0.01", 0.01), ("0.009", 3.0),
              ("3", 3.0), ("3600", 3.0), ("0", 3.0), ("-1", 3.0),
              ("nan", 3.0), ("fast", 3.0),
          ] as [(String?, TimeInterval)])
    func pollInterval(override: String?, expected: TimeInterval) {
        let environment = override.map { ["CMUX_VM_WAIT_POLL_SECONDS": $0] } ?? [:]
        #expect(CMUXCLI.vmReadyPollInterval(environment: environment) == expected)
    }
}
