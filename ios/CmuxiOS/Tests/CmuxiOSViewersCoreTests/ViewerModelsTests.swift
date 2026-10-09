import CmuxiOSFeatureKit
import CmuxiOSViewersCore
import CmuxMobileWire
import Foundation
import Testing

@MainActor
@Suite struct ViewerModelsTests {
    let target = ViewerTarget(hostID: MockFixtures.studio, hostName: "Studio", workspaceID: "ws_studio1", title: "cmux")
    let source = MockViewerContentSource(workspaces: ["ws_studio1": "cmux"])

    @Test func changesLoadStatusFilesTreeAndPatches() async throws {
        let model = ChangesModel(target: target, source: source)
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.status?.branch == "feat-viewers")
        #expect(model.root?.path == "/Users/demo/src/cmux")
        #expect(model.files.count == 5)
        #expect(model.files.allSatisfy { $0.patch == nil })
        #expect(model.tree.first?.name == "assets")
        let swift = try #require(model.files.first { $0.path == "Sources/App/Viewer.swift" })
        let document = try await model.document(for: swift)
        #expect(document.hunks.count == 2)
        #expect(document.additions == 5 && document.deletions == 3)
        let image = try #require(model.files.first { $0.isBinary })
        #expect(try await model.document(for: image).isBinary)
        #expect(model.absolutePath(of: swift) == "/Users/demo/src/cmux/Sources/App/Viewer.swift")
        await model.setScope(.staged)
        #expect(model.files.map(\.path) == ["README.md"])
    }

    @Test func aWorkspaceWithoutAFolderSaysSo() async {
        let model = ChangesModel(target: ViewerTarget(hostID: MockFixtures.studio, hostName: "Studio", workspaceID: "ws_none",
                                                      title: "x"), source: source)
        await model.load()
        #expect(model.phase == .failed(.noWorkspaceFolder))
        let unavailable = ChangesModel(target: target, source: UnavailableViewerContentSource())
        await unavailable.load()
        #expect(unavailable.phase == .failed(.noConnection))
    }

    @Test func browserListsFoldersFirstAndOpensFiles() async throws {
        let browser = FileBrowserModel(target: target, source: source)
        await browser.load()
        #expect(browser.phase == .loaded)
        #expect(browser.title == "cmux")
        #expect(browser.entries.map(\.name) == ["assets", "docs", "Sources", "Package.swift", "README.md", "TODO.md"])
        let docs = try #require(browser.entries.first { $0.name == "docs" })
        let child = FileBrowserModel(target: target, source: source, path: browser.childPath(docs), title: docs.name)
        await child.load()
        #expect(child.entries.map(\.name) == ["config.json", "guide.pdf", "notes.txt"])
        let readme = try #require(browser.entries.first { $0.name == "README.md" })
        let url = try await source.fetch(host: target.hostID, path: try #require(browser.childPath(readme)), size: nil)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(MarkdownDocument(parsing: text).taskProgress == (2, 4))
    }

    @Test func errorCodesMapToViewerErrors() {
        #expect(ViewerSourceError(code: "git.not_a_repo", message: "") == .notARepository)
        #expect(ViewerSourceError(code: "files.forbidden", message: "") == .forbidden)
        #expect(ViewerSourceError(code: "git.failed", message: "boom") == .failed("boom"))
    }
}
