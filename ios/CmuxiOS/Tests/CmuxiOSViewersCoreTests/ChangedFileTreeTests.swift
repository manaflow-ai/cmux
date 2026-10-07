import CmuxiOSViewersCore
import CmuxMobileWire
import Testing

@Suite struct ChangedFileTreeTests {
    @Test func foldersFirstCompressedAndCounted() {
        let files = ["README.md", "Sources/App/View2.swift", "Sources/App/View10.swift", "Sources/App/Deep/x.swift", "docs/a.md", "b.txt"]
            .map { GitChangedFile(path: $0, status: .modified) }
        let rows = ChangedFileTree(files).rows
        #expect(rows.map(\.name) == ["docs", "a.md", "Sources/App", "Deep", "x.swift", "View2.swift", "View10.swift", "b.txt", "README.md"])
        #expect(rows.map(\.depth) == [0, 1, 0, 1, 2, 1, 1, 0, 0])
        #expect(rows[2].id == "Sources/App")
        #expect(rows[2].kind == .folder(fileCount: 3))
        #expect(rows[4].id == "Sources/App/Deep/x.swift")
    }
}
