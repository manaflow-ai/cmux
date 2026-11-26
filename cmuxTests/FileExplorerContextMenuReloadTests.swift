import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// #12914: AppKit draws the context-menu highlight for the clicked row until
/// the menu closes and throws if a reload shrank the rows underneath it.
@MainActor
@Suite("File explorer context menu reloads", .serialized)
struct FileExplorerContextMenuReloadTests {
    @Test("Outline rows wait for an open context menu, then catch up")
    func reloadWaitsForContextMenuToClose() async throws {
        let store = FileExplorerStore()
        store.setProviderForTesting(LocalFileExplorerProvider(), reloadIfAvailable: false)
        let coordinator = FileExplorerPanelView.Coordinator(
            store: store,
            state: FileExplorerState(),
            onOpenFilePreview: { _ in }
        )
        let container = FileExplorerContainerView(coordinator: coordinator, presentation: .files)
        let outlineView = try #require(coordinator.outlineView as? FileExplorerNSOutlineView)
        let menu = try #require(outlineView.menu)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        store.rootNodes = (0..<3).map {
            FileExplorerNode(name: "file\($0)", path: "/tmp/cmux-12914/file\($0)", isDirectory: false)
        }
        coordinator.reloadIfNeeded()
        #expect(outlineView.numberOfRows == 3)

        outlineView.willOpenMenu(menu, with: event)
        #expect(outlineView.isContextMenuOpen)
        store.rootNodes = [store.rootNodes[0]]
        coordinator.reloadIfNeeded()
        #expect(outlineView.numberOfRows == 3, "Rows must not change under an open context menu")

        outlineView.didCloseMenu(menu, with: event)
        #expect(!outlineView.isContextMenuOpen)
        // The catch-up reload is queued on the main queue. This test itself runs
        // inside a main-queue block, where a nested run loop cannot drain that
        // queue, so yield back to it instead of spinning.
        let caughtUp = await AppKitTestEventPump().waitUntil(timeout: .seconds(2)) {
            outlineView.numberOfRows == 1
        }
        #expect(caughtUp, "The deferred reload must run after the menu closes; rows: \(outlineView.numberOfRows)")
        withExtendedLifetime(container) {}
    }
}
