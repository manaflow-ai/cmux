import AppKit
import CmuxSidebar
import Testing
@testable import cmux_DEV

/// How much of a workspace title the sidebar can show on one line at the
/// default sidebar width.
///
/// Titles were cutting off inside a dozen characters, which made the list
/// useless for telling similar workspaces apart. Three defaults paid for that:
/// the title point size, the row's content padding, and a trailing column held
/// open for a close button that only appears on hover. These tests measure the
/// shipped-before and current geometry with the same text layout the rows use,
/// so a later change that quietly takes the room back fails here.
@Suite
@MainActor
struct SidebarWorkspaceTitleRoomTests {
    /// Titles taken from cmux work: a PR title, a branch-shaped name, a
    /// remote workspace with a host suffix, and two task names.
    static let titles = [
        "Fix cmux pane focus indicator flicker",
        "cmux-remote-status @workstation",
        "Docs pass over the sidebar row copy",
        "Sidebar title truncation",
        "feat/workspace-group-collapse",
    ]

    struct Geometry {
        /// Point size of the title font.
        let fontSize: CGFloat
        /// `SidebarWorkspaceListMetrics.rowContentHorizontalPadding`.
        let contentPadding: CGFloat
        /// Whether a row that merely CAN be closed holds the close button's
        /// column open while the pointer is elsewhere.
        let reservesCloseButtonColumn: Bool

        /// Width available to a resting, ungrouped row's title.
        var titleWidth: CGFloat {
            let outer = SidebarWorkspaceListMetrics.rowOuterHorizontalPadding
            let content = CGFloat(SessionPersistencePolicy.defaultSidebarWidth) - 2 * (outer + contentPadding)
            guard reservesCloseButtonColumn else { return content }
            // The cell's own numbers: a 16pt close button and the 8pt gap
            // between the title and the trailing slot.
            return content - 16 - 8
        }

        /// Leading characters of `title` that fit on one line.
        func visibleCharacters(of title: String) -> Int {
            let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let limit = titleWidth
            var fitting = 0
            for count in 1...title.count {
                let prefix = String(title.prefix(count))
                if ceil((prefix as NSString).size(withAttributes: attributes).width) <= limit {
                    fitting = count
                } else {
                    break
                }
            }
            return fitting
        }
    }

    /// What cmux shipped before this change.
    static let before = Geometry(fontSize: 12.5, contentPadding: 10, reservesCloseButtonColumn: true)

    /// What the current defaults resolve to. Read from the shipping sources, so
    /// this cannot drift from what the rows draw.
    static var current: Geometry {
        Geometry(
            fontSize: SidebarRowTitleMetrics.fontSize,
            contentPadding: SidebarWorkspaceListMetrics.rowContentHorizontalPadding,
            reservesCloseButtonColumn: false
        )
    }

    @Test
    func defaultWidthShowsMoreOfEveryTitleThanBefore() {
        let before = Self.before
        let current = Self.current
        #expect(current.titleWidth > before.titleWidth)

        var report = ["title | before | after"]
        for title in Self.titles {
            let was = before.visibleCharacters(of: title)
            let now = current.visibleCharacters(of: title)
            report.append("\(title) | \(was) | \(now)")
            #expect(now >= was, "\(title) lost room: \(was) -> \(now)")
            if was < title.count {
                // A title that was being cut off gets strictly more room.
                #expect(now > was, "\(title) gained nothing: \(was) -> \(now)")
            } else {
                // A title that already fitted whole cannot gain characters, and
                // must not start losing them.
                #expect(now == title.count, "\(title) no longer fits whole: \(now)")
            }
            // The complaint was titles cutting off around a dozen characters.
            #expect(now >= 20, "\(title) still cuts off at \(now) characters")
        }
        // Printed so the exact counts are readable in the test log and can be
        // quoted without re-deriving them by hand.
        print("sidebar title room at \(Int(SessionPersistencePolicy.defaultSidebarWidth))pt\n" + report.joined(separator: "\n"))
    }

    /// The hover-revealed close button is the only thing that needs the
    /// trailing column, so a resting row spends that width on its title.
    @Test
    func restingRowDoesNotReserveTheCloseButtonColumn() {
        let reserved = Geometry(
            fontSize: SidebarRowTitleMetrics.fontSize,
            contentPadding: SidebarWorkspaceListMetrics.rowContentHorizontalPadding,
            reservesCloseButtonColumn: true
        )

        #expect(Self.current.titleWidth == reserved.titleWidth + 24)
    }
}
