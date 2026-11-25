import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Which window's Cmd+digit a notifications popover answers: only the one it hangs from (or its
/// own), so a digit pressed in another window still switches that window's workspaces.
@MainActor
@Suite("Notifications popover drawn rows")
struct NotificationsPopoverDrawnRowsTests {
    private static func rows(anchoredTo windowNumber: Int?) -> (NotificationsPopoverDrawnRows, [UUID]) {
        let rows = NotificationsPopoverDrawnRows()
        let ids = [UUID(), UUID(), UUID()]
        rows.ids = ids
        rows.anchorWindowNumber = windowNumber
        return (rows, ids)
    }

    @Test("a shown popover answers digits from the window it hangs from")
    func answersItsAnchorWindow() {
        let (rows, ids) = Self.rows(anchoredTo: 41)
        #expect(rows.ids(forWindowNumber: 41, isShown: true, popoverWindowNumber: 99) == ids)
    }

    @Test("a shown popover answers digits from its own window")
    func answersItsOwnWindow() {
        let (rows, ids) = Self.rows(anchoredTo: 41)
        #expect(rows.ids(forWindowNumber: 99, isShown: true, popoverWindowNumber: 99) == ids)
    }

    @Test("a digit from another window is not the popover's")
    func ignoresOtherWindows() {
        let (rows, _) = Self.rows(anchoredTo: 41)
        #expect(rows.ids(forWindowNumber: 7, isShown: true, popoverWindowNumber: 99) == nil)
    }

    @Test("a closed popover takes no digits, even from its window")
    func closedPopoverTakesNothing() {
        let (rows, _) = Self.rows(anchoredTo: 41)
        #expect(rows.ids(forWindowNumber: 41, isShown: false, popoverWindowNumber: 99) == nil)
    }
}
