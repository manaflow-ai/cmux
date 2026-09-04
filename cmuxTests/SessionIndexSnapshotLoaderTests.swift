import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct SessionIndexSnapshotLoaderTests {
    @MainActor
    @Test
    func reloadAndWaitReplacesAWarmCacheWithTheDurableSnapshot() async {
        let stale = entry(id: "stale", modified: 100)
        let fresh = entry(id: "fresh", modified: 200)
        let store = SessionIndexStore(
            snapshotLoader: SessionIndexSnapshotLoader { [fresh] in [fresh] }
        )
        store.replaceEntriesForTesting([stale])

        let entries = await store.reloadAndWaitForFreshEntries()

        #expect(entries.map(\.id) == ["fresh"])
        #expect(store.entries.map(\.id) == ["fresh"])
        #expect(!store.isLoading)
    }

    @MainActor
    @Test
    func twoThousandTranscriptCorpusScansOffMainActor() async throws {
        let corpus = try await SessionIndexSyntheticCorpus.create(
            projectCount: 20,
            transcriptsPerProject: 100
        )
        let loader = SessionIndexSnapshotLoader {
            corpus.loadEntries()
        }
        let entries = await loader.load()
        await corpus.remove()

        #expect(entries.count == 2_000)
        #expect(entries.allSatisfy { $0.title == "off-main" })
    }

    private func entry(id: String, modified: TimeInterval) -> SessionEntry {
        SessionEntry(
            id: id,
            agent: .claude,
            sessionId: id,
            title: id,
            cwd: "/tmp/repo",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: modified),
            fileURL: nil,
            specifics: .claude(
                model: nil,
                permissionMode: nil,
                configDirectoryForResume: nil
            )
        )
    }
}
