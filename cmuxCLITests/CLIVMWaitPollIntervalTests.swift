import Foundation
import Testing

@testable import cmux_cli

/// `cmux vm wait` polls `vm.status` at `CMUXCLI.vmReadyPollInterval`.
/// `CMUX_VM_WAIT_POLL_SECONDS` may only shorten the production 3 s cadence, so a
/// bad override can never outlive the command's `--timeout`.
@Suite("vm wait poll interval")
struct CLIVMWaitPollIntervalTests {
    @Test("Without an override the production cadence applies")
    func defaultCadence() {
        #expect(CMUXCLI.vmReadyPollInterval(environment: [:]) == 3)
    }

    @Test("A valid short override is honored", arguments: ["0.01", "0.05", "3"])
    func validOverride(raw: String) throws {
        let expected = try #require(TimeInterval(raw))
        #expect(CMUXCLI.vmReadyPollInterval(environment: ["CMUX_VM_WAIT_POLL_SECONDS": raw]) == expected)
    }

    @Test(
        "Oversized, tiny, non-finite and malformed overrides fall back to the command-safe cadence",
        arguments: ["3600", "3.5", "0.001", "0", "-1", "inf", "nan", "soon", ""]
    )
    func rejectedOverride(raw: String) {
        #expect(CMUXCLI.vmReadyPollInterval(environment: ["CMUX_VM_WAIT_POLL_SECONDS": raw]) == 3)
    }
}
