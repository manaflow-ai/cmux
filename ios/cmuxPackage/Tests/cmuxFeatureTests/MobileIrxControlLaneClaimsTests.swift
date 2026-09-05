import Foundation
import Testing
@testable import cmuxFeature

@Suite("Mobile Iroh control-lane ownership")
struct MobileIrxControlLaneClaimsTests {
    @Test
    func secondOwnerCannotTakeAnActiveSessionClaim() {
        var claims = MobileIrxControlLaneClaims()
        let firstOwner = UUID()
        let secondOwner = UUID()

        #expect(claims.claim(sessionID: "session-a", ownerID: firstOwner))
        #expect(!claims.claim(sessionID: "session-a", ownerID: secondOwner))
        #expect(claims.claim(sessionID: "session-a", ownerID: firstOwner))
    }

    @Test
    func releasingOneOwnerLeavesOtherSessionClaimsIntact() {
        var claims = MobileIrxControlLaneClaims()
        let firstOwner = UUID()
        let secondOwner = UUID()

        #expect(claims.claim(sessionID: "session-a", ownerID: firstOwner))
        #expect(claims.claim(sessionID: "session-b", ownerID: secondOwner))

        claims.release(ownerID: firstOwner)

        #expect(claims.claim(sessionID: "session-a", ownerID: secondOwner))
        #expect(!claims.claim(sessionID: "session-b", ownerID: firstOwner))
    }

    @Test
    func removingAllClaimsAllowsEverySessionToBeReclaimed() {
        var claims = MobileIrxControlLaneClaims()
        let firstOwner = UUID()
        let secondOwner = UUID()

        #expect(claims.claim(sessionID: "session-a", ownerID: firstOwner))
        #expect(claims.claim(sessionID: "session-b", ownerID: secondOwner))

        claims.removeAll()

        #expect(claims.claim(sessionID: "session-a", ownerID: secondOwner))
        #expect(claims.claim(sessionID: "session-b", ownerID: firstOwner))
    }
}
