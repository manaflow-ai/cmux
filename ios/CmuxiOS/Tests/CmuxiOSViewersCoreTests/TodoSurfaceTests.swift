import CmuxiOSFeatureKit
import CmuxiOSViewersCore
import CmuxMobileWire
import Foundation
import Testing

/// E4: the workspace todo list is a Markdown file in the workspace folder.
@MainActor
@Suite struct TodoSurfaceTests {
    let target = ViewerTarget(hostID: MockFixtures.studio, hostName: "Studio", workspaceID: "ws_studio1", title: "cmux")

    func file(_ name: String, size: UInt64 = 10) -> FilesListEntry {
        FilesListEntry(name: name, kind: .file, size: size, modifiedAt: 0)
    }

    @Test func locatorPicksByPriorityAndExactName() throws {
        let locator = WorkspaceTodoLocator()
        #expect(locator.subfolders == [".cmux"])
        let both = locator.pick(from: ["": [file("todo.md", size: 3), file("TODO.md", size: 7)]])
        #expect(both?.path == "TODO.md")
        #expect(both?.size == 7)
        #expect(locator.pick(from: ["": [file("Todo.md")]]) == nil)
        let nested = locator.pick(from: ["": [FilesListEntry(name: ".cmux", kind: .dir, size: 0, modifiedAt: 0)],
                                         ".cmux": [file("todo.md")]])
        #expect(nested?.path == ".cmux/todo.md")
        // A folder named like a candidate is not the list.
        #expect(locator.pick(from: ["": [FilesListEntry(name: "TODO.md", kind: .dir, size: 0, modifiedAt: 0)]]) == nil)
    }

    @Test func loadsTheMockTodoWithProgress() async throws {
        let model = TodoSurfaceModel(target: target, source: MockViewerContentSource(workspaces: ["ws_studio1": "cmux"]))
        await model.load()
        guard case .loaded(let url, let path, let done, let total) = model.state else {
            Issue.record("expected loaded, got \(model.state)")
            return
        }
        #expect(path == "/Users/demo/src/cmux/TODO.md")
        #expect(done == 2)
        #expect(total == 5)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("- [ ] Paste a screenshot"))
    }

    @Test func missingFileAndNoFolder() async {
        let missing = TodoSurfaceModel(target: target, source: MockViewerContentSource(workspaces: ["ws_studio1": "cmux"]),
                                       locator: WorkspaceTodoLocator(candidates: ["PLAN.md"]))
        await missing.load()
        #expect(missing.state == .missing)

        let other = ViewerTarget(hostID: MockFixtures.studio, hostName: "Studio", workspaceID: "ws_gone", title: "gone")
        let noFolder = TodoSurfaceModel(target: other, source: MockViewerContentSource(workspaces: ["ws_studio1": "cmux"]))
        await noFolder.load()
        #expect(noFolder.state == .failed(.noWorkspaceFolder))
    }
}
