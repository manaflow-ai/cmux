import CmuxBrowser
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct MarkdownFindTests {
    @Test func markdownPanelFindLifecycleUsesSharedWebViewFindBehavior() async throws {
        let fileURL = try temporaryMarkdownFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let evaluator = MarkdownFindScriptEvaluatorSpy(results: [
            #"{"total":3,"current":0}"#,
            #"{"total":3,"current":1}"#,
            #"{"total":3,"current":0}"#,
            "ok",
        ])
        let panel = MarkdownPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            findEvaluator: evaluator
        )
        defer { panel.close() }

        #expect(panel.searchState == nil)
        panel.startFind()
        let searchState = try #require(panel.searchState)
        #expect(searchState.needle.isEmpty)

        let searchTask = try #require(panel.updateFindNeedle("match"))
        await searchTask.value
        #expect(searchState.total == 3)
        #expect(searchState.selected == 0)
        #expect(evaluator.evaluatedScripts == [.search(query: "match")])

        let nextTask = try #require(panel.findNext())
        await nextTask.value
        #expect(searchState.selected == 1)
        #expect(evaluator.evaluatedScripts.last == .next())

        let previousTask = try #require(panel.findPrevious())
        await previousTask.value
        #expect(searchState.selected == 0)
        #expect(evaluator.evaluatedScripts.last == .previous())

        let clearTask = try #require(panel.hideFind())
        #expect(panel.searchState == nil)
        await clearTask.value
        #expect(evaluator.evaluatedScripts.last == .clear())
    }

    @Test func tabManagerRoutesConfiguredFindActionsToFocusedMarkdownPanel() throws {
        let fileURL = try temporaryMarkdownFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        defer {
            for panel in workspace.panels.values {
                panel.close()
            }
        }
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panel = try #require(workspace.newMarkdownSurface(
            inPane: pane,
            filePath: fileURL.path,
            focus: true
        ))

        #expect(manager.startSearch())
        #expect(panel.searchState != nil)
        #expect(manager.isFindVisible)

        manager.hideFind()
        #expect(panel.searchState == nil)
        #expect(!manager.isFindVisible)
    }

    private func temporaryMarkdownFile() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-markdown-find-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appending(path: "README.md")
        try "# Find\n\nmatch match match\n".write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}
