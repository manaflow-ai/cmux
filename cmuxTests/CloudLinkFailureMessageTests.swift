import CmuxCloud
import CmuxSurfaceCatalogModel
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
