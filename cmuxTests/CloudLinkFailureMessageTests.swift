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
        #expect(currentFailureMessage(for: asleep) == "This machine is asleep. Wake it to connect.")

        let unavailable = machineInfo(linkState: .unavailable, linkError: "cloud_api_unavailable")
        #expect(currentFailureMessage(for: unavailable) == "cmux cannot reach the Cloud service for this machine right now.")

        let prose = machineInfo(linkState: .error, linkError: "The remote daemon did not respond before the timeout.")
        #expect(currentFailureMessage(for: prose) == "The remote daemon did not respond before the timeout.")

        let empty = machineInfo(linkState: .error, linkError: "")
        #expect(currentFailureMessage(for: empty) == CloudDiagnosticFailure.network.label)
        #expect(currentFailureMessage(for: machineInfo(linkState: .error)) == CloudDiagnosticFailure.network.label)
    }

    private func currentFailureMessage(for info: SurfaceMachineInfo) -> String {
        info.linkError ?? CloudDiagnosticFailure.network.label
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
