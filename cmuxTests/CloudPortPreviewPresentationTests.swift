import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// What a person reads about a Cloud port: its preview tab title, whether it is
/// private, and the address `cmux vm ports` builds its PRIVATE URL from.
@Suite("Cloud port preview presentation")
struct CloudPortPreviewPresentationTests {
    @Test("A port preview tab is titled by port and machine, never by the raw private address")
    func previewTabTitle() {
        #expect(CloudTreePortPresentation.previewTabTitle(port: 3000, machineLabel: "vivid-newt") == ":3000 \u{00B7} vivid-newt")
        #expect(CloudTreePortPresentation.previewTabTitle(port: 3000, machineLabel: "  ") == ":3000")
        #expect(CloudTreePortPresentation.previewTabTitle(port: 3000, machineLabel: nil) == ":3000")
        #expect(!CloudTreePortPresentation.previewTabTitle(port: 9999, machineLabel: "vm").contains("10."))
    }

    @Test("A port is labelled private until a publication widens it, and public says so")
    func sharingStatus() {
        let unread = CloudTreePortPresentation.sharingStatus(nil)
        #expect(unread == CloudTreePortPresentation.sharingStatus(.unshared))
        #expect(unread.hasPrefix("Private"))
        #expect(CloudTreePortPresentation.sharingStatus(.team).contains("team"))
        #expect(CloudTreePortPresentation.sharingStatus(.public).hasPrefix("Public"))
        #expect(CloudTreePortPresentation.sharingStatus(.public).contains("anyone"))
    }

    @Test("The row tooltip states that the port is private by default")
    func rowToolTip() {
        let resource = CmuxTuiSnapshotParser.portBrowser(machine: .cloud("vm"), port: 3000, directURL: "http://10.0.0.7:3000")
        let presentation = CloudTreePortPresentation(resource: resource)
        #expect(presentation.title == ":3000")
        #expect(presentation.toolTip?.contains("Private") == true)
    }

    @Test("vm.status carries the private address `cmux vm ports` turns into PRIVATE URL")
    func summaryPayloadCarriesPrivateAddress() {
        let withAddress = TerminalController.socketWorkerVMSummaryPayload(VMSummary(
            id: "vm-1", provider: "fixture", status: "running", image: "desktop", createdAt: 0,
            addressIPv4: "10.140.85.1", addressIPv6: "fd00::1"
        ))
        #expect(withAddress["privateAddress"] as? String == "10.140.85.1")
        let withoutAddress = TerminalController.socketWorkerVMSummaryPayload(VMSummary(
            id: "vm-2", provider: "fixture", status: "running", image: "desktop", createdAt: 0
        ))
        #expect(withoutAddress["privateAddress"] == nil)
    }
}
