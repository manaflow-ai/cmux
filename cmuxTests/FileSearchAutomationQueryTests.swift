import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("File search automation query")
struct FileSearchAutomationQueryTests {
    @Test("Automation can reveal file search with an initial query")
    func automationSeedsFileSearchBeforeTheFirstRequest() throws {
        let store = FileExplorerStore()
        let state = FileExplorerState()
        let searchController = FileSearchAutomationSearchControllerSpy()
        let coordinator = FileExplorerPanelView.Coordinator(
            store: store,
            state: state,
            onOpenFilePreview: { _ in }
        )
        let container = FileExplorerContainerView(
            coordinator: coordinator,
            presentation: .find,
            searchController: searchController
        )
        store.applyWorkspaceRoot(.local(
            workspaceId: UUID(),
            path: "/tmp/cmux-find-seeded-query-test"
        ))
        container.updateHeader(store: store)
        container.updatePresentation(.find)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        defer { window.close() }
        searchController.searchRequests.removeAll()

        #expect(container.focusSearchField(initialQuery: "static needle"))

        let searchField = try #require(Self.findSearchField(in: container))
        #expect(searchField.stringValue == "static needle")
        #expect(searchController.searchRequests == ["static needle"])
    }

    private static func findSearchField(in root: NSView) -> NSSearchField? {
        if let field = root as? NSSearchField,
           field.accessibilityIdentifier() == "FileExplorerSearchField" {
            return field
        }
        for subview in root.subviews {
            if let field = findSearchField(in: subview) { return field }
        }
        return nil
    }
}
