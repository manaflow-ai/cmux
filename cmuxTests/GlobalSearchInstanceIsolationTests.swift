import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct GlobalSearchInstanceIsolationTests {
    @Test
    func databaseURLsAreScopedByBundleIdentifier() {
        let applicationSupportDirectory = URL(
            fileURLWithPath: "/tmp/cmux-search-instance-isolation",
            isDirectory: true
        )

        let stableURL = URL.cmuxSearchDatabaseURL(
            applicationSupportDirectory: applicationSupportDirectory,
            bundleIdentifier: "com.cmuxterm.app"
        )
        let taggedURL = URL.cmuxSearchDatabaseURL(
            applicationSupportDirectory: applicationSupportDirectory,
            bundleIdentifier: "com.cmuxterm.app.debug.sym7440"
        )

        #expect(stableURL != taggedURL)
        #expect(stableURL.path == "/tmp/cmux-search-instance-isolation/com.cmuxterm.app/search.db")
        #expect(taggedURL.path == "/tmp/cmux-search-instance-isolation/com.cmuxterm.app.debug.sym7440/search.db")
    }

    @Test
    func startingSecondBundleDoesNotClearFirstBundleIndex() async throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-search-instance-isolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let firstDatabaseURL = URL.cmuxSearchDatabaseURL(
            applicationSupportDirectory: fixtureDirectory,
            bundleIdentifier: "com.cmuxterm.app.debug.first"
        )
        let secondDatabaseURL = URL.cmuxSearchDatabaseURL(
            applicationSupportDirectory: fixtureDirectory,
            bundleIdentifier: "com.cmuxterm.app.debug.second"
        )

        let firstIndex = try SearchIndex(databaseURL: firstDatabaseURL)
        try await firstIndex.upsert(
            SearchIndexDocument(
                id: "first-instance-document",
                windowID: UUID(),
                workspaceID: UUID(),
                panelID: UUID(),
                kind: .markdown,
                title: "First Instance",
                location: "/tmp/first.md",
                anchor: "/tmp/first.md",
                text: "firstinstanceisolationtoken"
            )
        )
        let firstCoordinator = GlobalSearchCoordinator(databaseURL: firstDatabaseURL)
        #expect(await firstCoordinator.search(query: "firstinstanceisolationtoken").count == 1)

        let staleSecondIndex = try SearchIndex(databaseURL: secondDatabaseURL)
        try await staleSecondIndex.upsert(
            SearchIndexDocument(
                id: "stale-second-instance-document",
                windowID: UUID(),
                workspaceID: UUID(),
                panelID: UUID(),
                kind: .title,
                title: "Stale Second Instance",
                location: "Old Window",
                anchor: "title",
                text: "stalesecondinstanceindextoken"
            )
        )

        let secondCoordinator = GlobalSearchCoordinator(databaseURL: secondDatabaseURL)
        await secondCoordinator.start().value

        #expect(await firstCoordinator.search(query: "firstinstanceisolationtoken").count == 1)
        #expect(await secondCoordinator.search(query: "stalesecondinstanceindextoken").isEmpty)
    }
}
