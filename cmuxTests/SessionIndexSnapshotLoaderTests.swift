import Foundation
import Combine
import Testing
import CmuxAgentSessionStore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct SessionIndexSnapshotLoaderTests {
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
        let entries = await loader.load(
            ampSessionRepository: AmpHookSessionRepository()
        )
        await corpus.remove()

        #expect(entries.count == 2_000)
        #expect(entries.allSatisfy { $0.title == "off-main" })
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func manualReloadPublishesSessionsAddedSincePreviousSnapshot() async {
        let defaults = UserDefaults.standard
        let keys = ["sessionIndex.agentOrder", "sessionIndex.directoryOrder"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let firstEntry = Self.makeEntry(id: "first", title: "before refresh")
        let secondEntry = Self.makeEntry(id: "second", title: "after refresh")
        let source = SessionIndexReloadSource(snapshots: [[firstEntry], [firstEntry, secondEntry]])
        let store = SessionIndexStore(snapshotLoader: SessionIndexSnapshotLoader { await source.nextSnapshot() })

        store.reload()
        #expect(store.isLoading)
        for await isLoading in store.$isLoading.values {
            if !isLoading { break }
        }
        #expect(store.entries.map(\.title) == ["before refresh"])

        store.reload()
        #expect(store.isLoading)
        #expect(store.entries == [firstEntry], "Keep the current list while refreshing")
        for await isLoading in store.$isLoading.values {
            if !isLoading { break }
        }
        #expect(store.entries.map(\.id) == [firstEntry.id, secondEntry.id])
        #expect(store.entries.map(\.title) == ["before refresh", "after refresh"])
    }

    private static func makeEntry(id: String, title: String) -> SessionEntry {
        SessionEntry(
            id: "claude:/tmp/\(id).jsonl",
            agent: .claude,
            sessionId: id,
            title: title,
            cwd: "/tmp",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1),
            fileURL: nil,
            specifics: .claude(model: nil, permissionMode: nil, configDirectoryForResume: nil)
        )
    }
}

private actor SessionIndexReloadSource {
    private var snapshots: [[SessionEntry]]

    init(snapshots: [[SessionEntry]]) {
        self.snapshots = snapshots
    }

    func nextSnapshot() -> [SessionEntry] {
        snapshots.isEmpty ? [] : snapshots.removeFirst()
    }
}
