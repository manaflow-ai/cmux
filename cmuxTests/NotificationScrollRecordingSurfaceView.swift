import CmuxTerminalCore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class NotificationScrollRecordingSurfaceView: GhosttyNSView {
    private(set) var performedBindingActions: [String] = []
    var bindingActionResults: [Bool] = []

    /// Records the binding action so the test observes the production restore path.
    override func performBindingAction(_ action: String) -> Bool {
        performedBindingActions.append(action)
        return bindingActionResults.isEmpty ? true : bindingActionResults.removeFirst()
    }

    override func readAuthoritativeScrollbar(
        _ result: UnsafeMutablePointer<ghostty_surface_scrollbar_s>
    ) -> Bool {
        guard let scrollbar else { return false }
        result.pointee = cValue(scrollbar)
        return true
    }

    override func scrollToRow(
        _ row: UInt64,
        ifRowSpaceRevisionMatches rowSpaceRevision: UInt64,
        result: UnsafeMutablePointer<ghostty_surface_scrollbar_s>
    ) -> Bool {
        performedBindingActions.append("scroll_to_row:\(row)")
        let actionResult = bindingActionResults.isEmpty ? true : bindingActionResults.removeFirst()
        guard rowSpaceRevision == 1,
              actionResult,
              let scrollbar else { return false }
        result.pointee = cValue(scrollbar)
        return true
    }

    private func cValue(_ scrollbar: GhosttyScrollbar) -> ghostty_surface_scrollbar_s {
        ghostty_surface_scrollbar_s(
            total: scrollbar.total,
            offset: scrollbar.offset,
            len: scrollbar.len,
            row_space_revision: 1
        )
    }
}
