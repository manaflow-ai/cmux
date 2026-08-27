import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior coverage for the sidebar tab-name search index: the pure ranking
/// layer behind the top-of-sidebar search field.
final class SidebarTabSearchIndexTests: XCTestCase {
    private func candidate(
        id: String,
        title: String,
        subtitle: String = "",
        keywords: [String] = [],
        kind: SidebarTabSearchCandidate.Kind,
        rank: Int
    ) -> SidebarTabSearchCandidate {
        SidebarTabSearchCandidate(
            id: id,
            rank: rank,
            title: title,
            subtitle: subtitle,
            kindLabel: kind == .workspace ? "Workspace" : "Terminal",
            keywords: keywords,
            kind: kind
        )
    }

    private func sampleIndex() -> SidebarTabSearchIndex {
        SidebarTabSearchIndex(candidates: [
            candidate(id: "switcher.workspace.a", title: "web-frontend", kind: .workspace, rank: 0),
            candidate(id: "switcher.workspace.b", title: "api-server", kind: .workspace, rank: 1),
            candidate(id: "switcher.surface.1", title: "vercel-build", subtitle: "web-frontend", kind: .tab, rank: 2),
            candidate(id: "switcher.surface.2", title: "npm run dev", subtitle: "api-server", kind: .tab, rank: 3),
            candidate(id: "switcher.surface.3", title: "tail logs", subtitle: "api-server", keywords: ["build"], kind: .tab, rank: 4),
        ])
    }

    func testEmptyQueryReturnsNoResults() {
        let index = sampleIndex()
        XCTAssertTrue(index.rankedResults(matching: "", limit: 40).isEmpty)
        XCTAssertTrue(index.rankedResults(matching: "   ", limit: 40).isEmpty)
    }

    func testMatchesSurfaceTitle() {
        let results = sampleIndex().rankedResults(matching: "vercel", limit: 40)
        XCTAssertEqual(results.first?.id, "switcher.surface.1")
        XCTAssertEqual(results.first?.kind, .tab)
        XCTAssertFalse(results.first?.titleMatchIndices.isEmpty ?? true,
                       "a title hit should report highlight indices")
    }

    func testMatchesWorkspaceTitle() {
        let results = sampleIndex().rankedResults(matching: "frontend", limit: 40)
        XCTAssertEqual(results.first?.id, "switcher.workspace.a")
        XCTAssertEqual(results.first?.kind, .workspace)
    }

    func testTitleMatchOutranksKeywordOnlyMatch() {
        // "vercel-build" matches "build" in its title; "tail logs" matches only
        // via its keyword. The title hit must rank first.
        let results = sampleIndex().rankedResults(matching: "build", limit: 40)
        let ids = results.map(\.id)
        XCTAssertTrue(ids.contains("switcher.surface.1"))
        XCTAssertTrue(ids.contains("switcher.surface.3"))
        XCTAssertLessThan(
            ids.firstIndex(of: "switcher.surface.1") ?? .max,
            ids.firstIndex(of: "switcher.surface.3") ?? .max
        )
    }

    func testRespectsLimit() {
        let results = sampleIndex().rankedResults(matching: "e", limit: 2)
        XCTAssertLessThanOrEqual(results.count, 2)
    }

    func testNonMatchingQueryReturnsNoResults() {
        XCTAssertTrue(sampleIndex().rankedResults(matching: "zzzznomatch", limit: 40).isEmpty)
    }
}
