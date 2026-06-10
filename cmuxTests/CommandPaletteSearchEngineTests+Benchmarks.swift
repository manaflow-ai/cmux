import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Search performance benchmarks
extension CommandPaletteSearchEngineTests {
    func testCommandSearchBenchmarkBeatsLegacyPipeline() {
        let entries = makeCommandEntries(count: 900)
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        let queries = repeatedQueries(
            ["rename", "rename tab", "open dir", "toggle side", "apply update", "notif", "split right", "cmux"],
            repetitions: 12
        )

        for query in queries.prefix(8) {
            _ = referenceResults(entries: entries, query: query)
            _ = CommandPaletteSearchEngine.search(entries: corpus, query: query) { _, _ in 0 }
        }

        let referenceMs = benchmarkElapsedMs {
            for query in queries {
                _ = referenceResults(entries: entries, query: query)
            }
        }
        let optimizedMs = benchmarkElapsedMs {
            for query in queries {
                _ = CommandPaletteSearchEngine.search(entries: corpus, query: query) { _, _ in 0 }
            }
        }

        print(String(format: "BENCH cmd+shift+p reference=%.2fms optimized=%.2fms", referenceMs, optimizedMs))
        XCTAssertLessThan(
            optimizedMs,
            referenceMs * 1.25,
            "Optimized command search regressed significantly: reference=\(referenceMs) optimized=\(optimizedMs)"
        )
    }

    func testSwitcherSearchBenchmarkBeatsLegacyPipeline() {
        let entries = makeSwitcherEntries(count: 400)
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        let queries = repeatedQueries(
            ["workspace 12", "phoenix", "feature-18", "rename-tab", "3007", "9202", "switch", "worktrees"],
            repetitions: 12
        )

        for query in queries.prefix(8) {
            _ = referenceResults(entries: entries, query: query)
            _ = CommandPaletteSearchEngine.search(entries: corpus, query: query) { _, _ in 0 }
        }

        let referenceMs = benchmarkElapsedMs {
            for query in queries {
                _ = referenceResults(entries: entries, query: query)
            }
        }
        let optimizedMs = benchmarkElapsedMs {
            for query in queries {
                _ = CommandPaletteSearchEngine.search(entries: corpus, query: query) { _, _ in 0 }
            }
        }

        print(String(format: "BENCH cmd+p reference=%.2fms optimized=%.2fms", referenceMs, optimizedMs))
        XCTAssertLessThan(
            optimizedMs,
            referenceMs * 1.25,
            "Optimized switcher search regressed significantly: reference=\(referenceMs) optimized=\(optimizedMs)"
        )
    }

    func testLargeWorkspaceSwitcherSearchBenchmarkAvoidsPerQueryPreparationCost() {
        let entries = makeLargeWorkspaceSwitcherEntries(count: 800)
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        let queries = repeatedQueries(
            [
                "workspace 799",
                "palette latency",
                "feature 401",
                "cmd-p-search",
                "project-642",
                "4207",
                "9204",
                "Window 3",
            ],
            repetitions: 3
        )

        for query in queries.prefix(8) {
            _ = referenceResults(entries: entries, query: query)
            _ = CommandPaletteSearchEngine.search(entries: corpus, query: query) { _, _ in 0 }
        }

        let referenceMs = benchmarkElapsedMs {
            for query in queries {
                _ = referenceResults(entries: entries, query: query)
            }
        }
        let optimizedMs = benchmarkElapsedMs {
            for query in queries {
                _ = CommandPaletteSearchEngine.search(entries: corpus, query: query) { _, _ in 0 }
            }
        }

        print(String(format: "BENCH cmd+p large-workspaces reference=%.2fms optimized=%.2fms", referenceMs, optimizedMs))
        XCTAssertLessThan(
            optimizedMs,
            referenceMs * 0.80,
            "Large switcher search should reuse prepared corpus data: reference=\(referenceMs) optimized=\(optimizedMs)"
        )
    }

    func testFastTypingPreviewSearchBenchmarkReportsEstimatedDroppedFrames() {
        let entries = makeLargeWorkspaceSwitcherEntries(count: 800)
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        let visibleCandidateCorpus = Array(corpus.prefix(128))
        let queries = repeatedQueries(
            fastTypingPrefixes("cmd-p-search") + fastTypingPrefixes("palette latency"),
            repetitions: 2
        )

        for query in queries.prefix(8) {
            _ = CommandPaletteSearchEngine.search(entries: corpus, query: query) { _, _ in 0 }
            _ = CommandPaletteSearchEngine.search(entries: corpus, query: query, resultLimit: 100) { _, _ in 0 }
            _ = CommandPaletteSearchEngine.search(entries: visibleCandidateCorpus, query: query, resultLimit: 48) { _, _ in 0 }
        }

        var fullDurationsMs: [Double] = []
        var cappedFullDurationsMs: [Double] = []
        var previewDurationsMs: [Double] = []
        fullDurationsMs.reserveCapacity(queries.count)
        cappedFullDurationsMs.reserveCapacity(queries.count)
        previewDurationsMs.reserveCapacity(queries.count)

        for query in queries {
            fullDurationsMs.append(
                benchmarkElapsedMs {
                    _ = CommandPaletteSearchEngine.search(entries: corpus, query: query) { _, _ in 0 }
                }
            )
            cappedFullDurationsMs.append(
                benchmarkElapsedMs {
                    _ = CommandPaletteSearchEngine.search(entries: corpus, query: query, resultLimit: 100) { _, _ in 0 }
                }
            )
            previewDurationsMs.append(
                benchmarkElapsedMs {
                    _ = CommandPaletteSearchEngine.search(entries: visibleCandidateCorpus, query: query, resultLimit: 48) { _, _ in 0 }
                }
            )
        }

        let fullMs = fullDurationsMs.reduce(0, +)
        let cappedFullMs = cappedFullDurationsMs.reduce(0, +)
        let previewMs = previewDurationsMs.reduce(0, +)
        let fullDroppedFrames = estimatedDroppedFrames(for: fullDurationsMs)
        let cappedFullDroppedFrames = estimatedDroppedFrames(for: cappedFullDurationsMs)
        let previewDroppedFrames = estimatedDroppedFrames(for: previewDurationsMs)
        let maxFullMs = fullDurationsMs.max() ?? 0
        let maxCappedFullMs = cappedFullDurationsMs.max() ?? 0
        let maxPreviewMs = previewDurationsMs.max() ?? 0
        let maxPreviewQuery = previewDurationsMs.enumerated().max(by: { $0.element < $1.element }).map {
            queries[$0.offset]
        } ?? ""

        print(String(
            format: "BENCH cmd+p fast-typing full=%.2fms cappedFull=%.2fms visiblePreview=%.2fms maxFull=%.2fms maxCappedFull=%.2fms maxVisiblePreview=%.2fms maxVisiblePreviewQuery=%@ fullDroppedFrames=%d cappedFullDroppedFrames=%d visiblePreviewDroppedFrames=%d",
            fullMs,
            cappedFullMs,
            previewMs,
            maxFullMs,
            maxCappedFullMs,
            maxPreviewMs,
            maxPreviewQuery,
            fullDroppedFrames,
            cappedFullDroppedFrames,
            previewDroppedFrames
        ))
        XCTAssertLessThan(
            cappedFullMs,
            fullMs,
            "Capped full-corpus search should avoid preparing results the UI cannot render: full=\(fullMs) capped=\(cappedFullMs)"
        )
        XCTAssertLessThanOrEqual(
            cappedFullDroppedFrames,
            fullDroppedFrames,
            "Capped full-corpus search should not increase estimated frame-budget misses: full=\(fullDroppedFrames) capped=\(cappedFullDroppedFrames)"
        )
        XCTAssertLessThan(
            previewMs,
            cappedFullMs,
            "Visible-candidate preview search should avoid full-corpus work during fast typing: capped=\(cappedFullMs) preview=\(previewMs)"
        )
        XCTAssertLessThanOrEqual(
            previewDroppedFrames,
            cappedFullDroppedFrames,
            "Preview search should not increase estimated frame-budget misses: capped=\(cappedFullDroppedFrames) preview=\(previewDroppedFrames)"
        )
    }
}
