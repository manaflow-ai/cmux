import CMUXMobileCore
import CoreGraphics
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension MobileHostWorkspaceTicketAuthorizationTests {
    @Test func nextTransportPairRequiresMacWideAttachTicket() throws {
        let scopedTicket = try scopedAttachTicket(
            workspaceID: "workspace", terminalID: "terminal")
        let macWideTicket = try scopedAttachTicket(workspaceID: "", terminalID: nil)
        let request = MobileHostRPCRequest(
            id: "next-pair",
            method: "mobile.next_transport.pair",
            params: [
                "device_id": "phone",
                "device_public_key": Data(repeating: 1, count: 32).base64EncodedString(),
                "app_identity": "dev.cmux.next.ios",
            ],
            auth: MobileHostRPCAuth(attachToken: scopedTicket.authToken, stackAccessToken: nil)
        )
        #expect(
            MobileHostService.ticketAuthorizationError(
                ticket: scopedTicket, request: request)?.code == "forbidden")
        // Authorization is evaluated from the presented ticket's scope; the
        // request auth field is not a second, mutable scope source.
        #expect(MobileHostService.ticketAuthorizationError(ticket: macWideTicket, request: request) == nil)
    }

}
