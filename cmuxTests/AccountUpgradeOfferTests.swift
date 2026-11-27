import CMUXMobileCore
import CmuxCommandPalette
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Every upgrade entrypoint (account menu, sidebar help menu, Help menu,
/// command palette) offers the tier above the account's plan: Free and Go
/// see Pro, Pro sees Max, and Max sees nothing.
@MainActor
struct AccountUpgradeOfferTests {
    @Test func menuTitlesNameTheOfferedTier() {
        #expect(ProUpgradePresenter.upgradeMenuTitle(for: .pro) == String(
            localized: "menu.help.upgradeToPro", defaultValue: "Upgrade to cmux Pro…"
        ))
        #expect(ProUpgradePresenter.upgradeMenuTitle(for: .max) == String(
            localized: "menu.help.upgradeToMax", defaultValue: "Upgrade to cmux Max…"
        ))
    }

    @Test(arguments: [
        (CmuxPlanTier.free, Optional(CmuxPlanTier.pro)),
        (CmuxPlanTier.go, Optional(CmuxPlanTier.pro)),
        (CmuxPlanTier.pro, Optional(CmuxPlanTier.max)),
        (CmuxPlanTier.max, nil),
    ])
    func paletteCommandFollowsTheTier(tier: CmuxPlanTier, expected: CmuxPlanTier?) throws {
        let command = try #require(ContentView.commandPaletteProCommandContributions().first {
            $0.commandId == ContentView.commandPaletteProUpgradeCommandId
        })
        var context = CommandPaletteContextSnapshot()
        let offer = CmuxPlanTier.upgradeOffer(isSignedIn: true, knownTier: tier)
        context.setString(
            CommandPaletteContextKeys.accountUpgradeOffer,
            ContentView.commandPaletteUpgradeOfferValue(offer)
        )
        #expect(command.when(context) == (expected != nil))
        if let expected {
            #expect(command.title(context) == ProUpgradePresenter.upgradeCommandTitle(for: expected))
        }
    }

    @Test func paletteHidesTheUpgradeWhileThePlanIsUnknown() throws {
        let command = try #require(ContentView.commandPaletteProCommandContributions().first {
            $0.commandId == ContentView.commandPaletteProUpgradeCommandId
        })
        var context = CommandPaletteContextSnapshot()
        context.setString(
            CommandPaletteContextKeys.accountUpgradeOffer,
            ContentView.commandPaletteUpgradeOfferValue(CmuxPlanTier.upgradeOffer(isSignedIn: true, knownTier: nil))
        )
        #expect(!command.when(context))
    }

    @Test func footerBadgeIsHiddenForProAndMax() {
        for tier in CmuxPlanTier.allCases {
            #expect(
                SidebarFooterPresentationPolicy.isUpgradeVisible(isProActive: tier.includesPro) == !tier.includesPro,
                "\(tier)"
            )
        }
    }
}
