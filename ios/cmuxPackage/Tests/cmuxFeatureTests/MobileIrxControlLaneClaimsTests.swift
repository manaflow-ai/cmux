import Foundation
import Testing

@testable import cmuxFeature

@Suite("IRX control lane claims")
struct MobileIrxControlLaneClaimsTests {
    @Test
    func distinctMacSessionsRemainIndependentlyOwned() {
        var claims = MobileIrxControlLaneClaims()
        let firstOwner = UUID()
        let secondOwner = UUID()

        #expect(claims.claim(sessionID: "mac-a-session", ownerID: firstOwner))
        #expect(claims.claim(sessionID: "mac-b-session", ownerID: secondOwner))
        #expect(!claims.claim(sessionID: "mac-a-session", ownerID: secondOwner))

        claims.release(ownerID: firstOwner)

        #expect(claims.claim(sessionID: "mac-a-session", ownerID: secondOwner))
        #expect(claims.claim(sessionID: "mac-b-session", ownerID: secondOwner))
    }
}
