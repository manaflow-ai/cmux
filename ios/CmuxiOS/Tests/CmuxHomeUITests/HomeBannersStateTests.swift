import CmuxHomeCore
import Testing
@testable import CmuxHomeUI

/// Home's banner header: every set of cards has its own registered element
/// kind (so the header is measured again when its cards change), and the old
/// kinds keep their names.
@Suite struct HomeBannersStateTests {
    private static let update = HomeUpdateRequired(minimumVersion: "1.2.0")

    @Test func everySetOfCardsHasARegisteredKindOfItsOwn() {
        var seen: [String] = []
        for update in [nil, Self.update] {
            for chief in [nil, HomeChiefBanner.off, .turningOn, .failed, .unavailable] {
                for offline in [false, true] {
                    let state = HomeBannersView.State(updateRequired: update, chief: chief, isOffline: offline)
                    guard let kind = state.elementKind else {
                        #expect(update == nil && chief == nil && !offline)
                        continue
                    }
                    #expect(HomeBannersView.elementKinds.contains(kind))
                    seen.append(kind)
                }
            }
        }
        #expect(Set(HomeBannersView.elementKinds).count == HomeBannersView.elementKinds.count)
        #expect(Set(seen) == Set(HomeBannersView.elementKinds))
    }

    @Test func turnOnAndItsProgressShareAKindAndTryAgainHasAnother() {
        let off = HomeBannersView.State(chief: .off).elementKind
        #expect(off == "home.banners.chief")
        #expect(HomeBannersView.State(chief: .turningOn).elementKind == off)
        #expect(HomeBannersView.State(chief: .failed).elementKind == "home.banners.chief-failed")
        #expect(HomeBannersView.State(chief: .unavailable).elementKind == "home.banners.chief-unavailable")
    }

    @Test func theCardsWithoutAChiefKeepTheirKinds() {
        #expect(HomeBannersView.State(updateRequired: Self.update).elementKind == "home.banners.update")
        #expect(HomeBannersView.State(isOffline: true).elementKind == "home.banners.offline")
        #expect(HomeBannersView.State(updateRequired: Self.update, isOffline: true).elementKind == "home.banners.update-offline")
        #expect(HomeBannersView.State(updateRequired: Self.update, chief: .off, isOffline: true).elementKind == "home.banners.update-chief-offline")
    }
}
