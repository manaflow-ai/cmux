import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct SidebarTypographyTests {
    @Test func productionDefaultsReserveWeightForIdentityAndState() {
        let typography = SidebarTypography()

        #expect(typography.restingTitle == .medium)
        #expect(typography.unreadTitle == .semibold)
        #expect(typography.groupName == .semibold)
        #expect(typography.affordance == .regular)
        #expect(typography.restingTitleSwiftUI == .medium)
        #expect(typography.unreadTitleSwiftUI == .semibold)
        #expect(typography.groupNameSwiftUI == .semibold)
        #expect(typography.affordanceSwiftUI == .regular)
    }

    @Test func titleWeightTracksUnreadStateInBothEngines() {
        let typography = SidebarTypography()

        #expect(typography.title(hasUnread: false) == typography.restingTitle)
        #expect(typography.title(hasUnread: true) == typography.unreadTitle)
        #expect(typography.titleSwiftUI(hasUnread: false) == typography.restingTitleSwiftUI)
        #expect(typography.titleSwiftUI(hasUnread: true) == typography.unreadTitleSwiftUI)
    }

    @Test func constructedVariantsFlowThroughTitleSelection() {
        let typography = SidebarTypography(restingTitle: .light, unreadTitle: .black)

        #expect(typography.title(hasUnread: false) == .light)
        #expect(typography.title(hasUnread: true) == .black)
    }
}
