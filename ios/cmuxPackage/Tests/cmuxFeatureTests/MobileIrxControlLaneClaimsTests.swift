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

        let initialClaim = claims.claim(sessionID: "session-a", ownerID: firstOwner)
        #expect(initialClaim)
        let competingClaim = claims.claim(sessionID: "session-a", ownerID: secondOwner)
        #expect(!competingClaim)
        let retainedClaim = claims.claim(sessionID: "session-a", ownerID: firstOwner)
        #expect(retainedClaim)
    }

    @Test
    func releasingOneOwnerLeavesOtherSessionClaimsIntact() {
        var claims = MobileIrxControlLaneClaims()
        let firstOwner = UUID()
        let secondOwner = UUID()

        let firstClaim = claims.claim(sessionID: "session-a", ownerID: firstOwner)
        #expect(firstClaim)
        let secondClaim = claims.claim(sessionID: "session-b", ownerID: secondOwner)
        #expect(secondClaim)

        claims.release(ownerID: firstOwner)

        let releasedClaim = claims.claim(sessionID: "session-a", ownerID: secondOwner)
        #expect(releasedClaim)
        let competingClaim = claims.claim(sessionID: "session-b", ownerID: firstOwner)
        #expect(!competingClaim)
    }

    @Test
    func removingAllClaimsAllowsEverySessionToBeReclaimed() {
        var claims = MobileIrxControlLaneClaims()
        let firstOwner = UUID()
        let secondOwner = UUID()

        let firstClaim = claims.claim(sessionID: "session-a", ownerID: firstOwner)
        #expect(firstClaim)
        let secondClaim = claims.claim(sessionID: "session-b", ownerID: secondOwner)
        #expect(secondClaim)

        claims.removeAll()

        let firstReclaimed = claims.claim(sessionID: "session-a", ownerID: secondOwner)
        #expect(firstReclaimed)
        let secondReclaimed = claims.claim(sessionID: "session-b", ownerID: firstOwner)
        #expect(secondReclaimed)
    }
}
