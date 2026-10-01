import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud link failure messages")
struct CloudLinkFailureMessageTests {
    @Test("states and diagnostics produce user-facing link failure copy")
    func linkFailureMessageUsesStateAndProse() {
        let asleep = machineInfo(linkState: .asleep)
        #expect(asleep.linkFailureMessage == "This machine is asleep. Wake it to connect.")

        let asleepError = CloudMachineLink.LinkError.failureMessage(asleep.linkFailureMessage)
        #expect(CloudMachineLink.errorText(asleepError) == asleep.linkFailureMessage)

        let unavailable = machineInfo(linkState: .unavailable, linkError: "cloud_api_unavailable")
        #expect(unavailable.linkFailureMessage == "cmux cannot reach the Cloud service for this machine right now.")

        let unavailableError = CloudMachineLink.LinkError.failureMessage(unavailable.linkFailureMessage)
        #expect(CloudMachineLink.errorText(unavailableError) == unavailable.linkFailureMessage)

        let reasonCode = machineInfo(linkState: .error, linkError: "daemon_not_ready")
        #expect(reasonCode.linkFailureMessage == CloudDiagnosticFailure.network.label)

        let prose = machineInfo(linkState: .error, linkError: "The remote daemon did not respond before the timeout.")
        #expect(prose.linkFailureMessage == "The remote daemon did not respond before the timeout.")

        let empty = machineInfo(linkState: .error, linkError: "")
        #expect(empty.linkFailureMessage == CloudDiagnosticFailure.network.label)
        #expect(machineInfo(linkState: .error).linkFailureMessage == CloudDiagnosticFailure.network.label)
    }

    @Test("The socket payload carries prose alongside the diagnostic token")
    func socketPayloadCarriesLinkFailureMessage() {
        let info = machineInfo(linkState: .unavailable, linkError: "cloud_api_unavailable")
        let payload = TerminalController.surfaceMachinePayload(info)
        #expect(payload["link_error"] as? String == "cloud_api_unavailable")
        #expect(payload["link_error_message"] as? String == info.linkFailureMessage)
    }

    @Test("vm tree never prints a raw link failure token")
    func vmTreeUsesLinkFailureMessage() {
        let info = machineInfo(linkState: .unavailable, linkError: "cloud_api_unavailable")
        let message = info.linkFailureMessage
        var machine = TerminalController.surfaceMachinePayload(info)
        machine["remote_workspaces"] = [[String: Any]]()
        let lines = CMUXCLI.vmTreeLines(machine: machine, resources: [])
        let output = lines.joined(separator: "\n")
        #expect(output.contains(message))
        #expect(!output.contains("cloud_api_unavailable"))
    }

    @Test("vm tree uses readable fallback for legacy link payloads")
    func vmTreeUsesReadableLegacyFallback() {
        let info = machineInfo(linkState: .unavailable, linkError: "cloud_api_unavailable")
        var machine = TerminalController.surfaceMachinePayload(info)
        machine.removeValue(forKey: "link_error_message")
        machine["remote_workspaces"] = [[String: Any]]()
        let output = CMUXCLI.vmTreeLines(machine: machine, resources: []).joined(separator: "\n")
        #expect(output.contains("Cloud link is unavailable. Refresh to reconnect."))
        #expect(!output.contains("cloud_api_unavailable"))
    }

    private func machineInfo(linkState: SurfaceLinkState, linkError: String? = nil) -> SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: .cloud("link-copy-test"),
            name: "Link copy test",
            status: "running",
            hasDesktop: false,
            linkState: linkState,
            linkError: linkError
        )
    }
}
