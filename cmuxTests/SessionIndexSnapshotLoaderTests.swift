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
}
