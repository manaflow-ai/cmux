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
    func twoThousandTranscriptCorpusScansOffMainActorWithinBudget() async throws {
        let corpus = try await SessionIndexSyntheticCorpus.create(
            projectCount: 20,
            transcriptsPerProject: 100
        )
        let loader = SessionIndexSnapshotLoader {
            corpus.loadEntries()
        }
        let clock = ContinuousClock()
        let start = clock.now

        let entries = await loader.load()
        let elapsed = start.duration(to: clock.now)
        await corpus.remove()

        #expect(entries.count == 2_000)
        #expect(entries.allSatisfy { $0.title == "off-main" })
        #expect(
            elapsed < .seconds(10),
            "A 2,000-transcript filesystem snapshot should complete within the bounded CI budget"
        )
    }
}
