import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct FeedFocusRoutingTests {
    private final class ScopedFeedResponder: NSView, FeedScopedKeyboardFocusResponder {
        let feedFocusScopeID: UUID

        init(scopeID: UUID) {
            self.feedFocusScopeID = scopeID
            super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        }

        required init?(coder: NSCoder) {
            nil
        }

        override var acceptsFirstResponder: Bool { true }
    }

    @Test func feedPaneResponderDoesNotClaimRightSidebarFocus() {
        let controller = MainWindowFocusController(
            windowId: UUID(),
            window: nil,
            tabManager: TabManager(),
            fileExplorerState: FileExplorerState()
        )

        #expect(!controller.ownsRightSidebarFocus(ScopedFeedResponder(scopeID: UUID())))
    }

    @Test func rightSidebarFeedHostOwnsOnlyItsFocusScope() {
        let controller = MainWindowFocusController(
            windowId: UUID(),
            window: nil,
            tabManager: TabManager(),
            fileExplorerState: FileExplorerState()
        )
        let host = FeedKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        let matchingResponder = ScopedFeedResponder(scopeID: host.feedFocusScopeID)
        let paneResponder = ScopedFeedResponder(scopeID: UUID())
        controller.registerFeedHost(host)

        #expect(controller.ownsRightSidebarFocus(matchingResponder))
        #expect(!controller.ownsRightSidebarFocus(paneResponder))
    }

    @Test func onlySidebarFeedPlacementUsesSidebarFocusCoordinator() {
        #expect(FeedPlacement.rightSidebar.usesRightSidebarFocusCoordinator)
        #expect(!FeedPlacement.pane.usesRightSidebarFocusCoordinator)
    }
}
