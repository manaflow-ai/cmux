import Foundation
import Testing
import CmuxTextActions

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The Snippets sidebar store: loads text actions from a config store,
/// filters through CmuxSnippetSearch, keeps the keyboard selection valid.
@MainActor
struct SnippetsSidebarStoreTests {
    private func makeConfigStore(_ json: String) throws -> (store: CmuxConfigStore, url: URL, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-snippets-sidebar-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("cmux.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        let store = CmuxConfigStore(globalConfigPath: url.path, localConfigPath: nil, startFileWatchers: false)
        store.loadAll()
        return (store, url, { try? FileManager.default.removeItem(at: root) })
    }

    private let config = """
    {
      "actions": {
        "run-tests": { "type": "command", "title": "Run Tests", "command": "npm test" },
        "fixup": { "type": "text", "category": "Git", "title": "Fixup", "keywords": ["amend"], "text": "git commit --fixup HEAD" },
        "review": { "type": "text", "title": "Review Prompt", "text": "review this" }
      }
    }
    """

    @Test func attachLoadsOnlyTextActionsWithKeywordsAndSelectsTheTop() throws {
        let made = try makeConfigStore(config)
        defer { made.cleanup() }
        let store = SnippetsSidebarStore()
        store.attach(configStore: made.store)
        #expect(store.entries.map(\.actionID).sorted() == ["fixup", "review"])
        #expect(store.entries.first { $0.actionID == "fixup" }?.keywords == ["amend"])
        #expect(store.results.map(\.title) == ["Fixup", "Review Prompt"])
        #expect(store.selectedActionID == "fixup")
    }

    @Test func queryFiltersResultsAndClampsSelection() throws {
        let made = try makeConfigStore(config)
        defer { made.cleanup() }
        let store = SnippetsSidebarStore()
        store.attach(configStore: made.store)
        store.select(actionID: "review")
        #expect(store.selectedActionID == "review")
        store.query = "amend"
        #expect(store.results.map(\.actionID) == ["fixup"])
        #expect(store.selectedActionID == "fixup")
        store.query = "nothing-matches"
        #expect(store.results.isEmpty)
        #expect(store.selectedActionID == nil)
        #expect(store.selectedEntry == nil)
    }

    @Test func moveSelectionStaysInsideResults() throws {
        let made = try makeConfigStore(config)
        defer { made.cleanup() }
        let store = SnippetsSidebarStore()
        store.attach(configStore: made.store)
        store.moveSelection(by: -1)
        #expect(store.selectedActionID == "fixup")
        store.moveSelection(by: 1)
        #expect(store.selectedActionID == "review")
        store.moveSelection(by: 5)
        #expect(store.selectedActionID == "review")
        #expect(store.selectedEntry?.title == "Review Prompt")
    }

    @Test func configReloadRefreshesEntriesAndDetachStopsObserving() throws {
        let made = try makeConfigStore(config)
        defer { made.cleanup() }
        let store = SnippetsSidebarStore()
        store.attach(configStore: made.store)
        try """
        { "actions": { "only": { "type": "text", "title": "Only", "text": "uptime" } } }
        """.write(to: made.url, atomically: true, encoding: .utf8)
        made.store.loadAll()
        #expect(store.entries.map(\.actionID) == ["only"])
        #expect(store.selectedActionID == "only")

        store.detach()
        try config.write(to: made.url, atomically: true, encoding: .utf8)
        made.store.loadAll()
        #expect(store.entries.map(\.actionID) == ["only"], "a detached store no longer follows reloads")
    }
}
