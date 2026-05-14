import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CommandPaletteNucleoFFITests: XCTestCase {
    private struct FixtureEntry {
        let id: String
        let rank: Int
        let title: String
        let searchableTexts: [String]
    }

    private struct FixtureResult: Equatable {
        let id: String
        let rank: Int
        let title: String
        let score: Int
    }

    private struct NucleoResult: Equatable {
        let id: String
        let rank: Int
        let title: String
        let score: Double
    }

    private struct FFICandidateSpan {
        let titleOffset: Int
        let titleLength: Int
        let searchOffset: Int
        let searchLength: Int
        let rank: Int32
    }

    private struct FFIMatch {
        var index: Int
        var score: Double
        var rank: Int32
    }

    private final class NucleoLibrary {
        typealias CreateIndex = @convention(c) (
            UnsafePointer<UInt8>?,
            Int,
            UnsafeRawPointer?,
            Int
        ) -> OpaquePointer?
        typealias DestroyIndex = @convention(c) (OpaquePointer?) -> Void
        typealias SearchIndex = @convention(c) (
            OpaquePointer?,
            UnsafePointer<UInt8>?,
            Int,
            Int,
            UnsafeMutableRawPointer?,
            Int,
            UnsafeMutablePointer<Int>?
        ) -> Int32
        typealias Version = @convention(c) () -> UInt32

        let handle: UnsafeMutableRawPointer
        let createIndex: CreateIndex
        let destroyIndex: DestroyIndex
        let searchIndex: SearchIndex
        let version: Version

        init() throws {
            let environment = ProcessInfo.processInfo.environment
            let defaultPath = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Native/CommandPaletteNucleoFFI/target/release/libcmux_command_palette_nucleo_ffi.dylib")
                .path
            let path = environment["CMUX_NUCLEO_FFI_LIB"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultPath
            guard FileManager.default.fileExists(atPath: path) else {
                throw XCTSkip("Build the nucleo FFI dylib before running comparison tests")
            }
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
                throw NSError(
                    domain: "CommandPaletteNucleoFFITests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "dlopen failed: \(Self.dlerrorText())"]
                )
            }
            self.handle = handle
            self.createIndex = try Self.symbol(
                "cmux_nucleo_index_create",
                from: handle,
                as: CreateIndex.self
            )
            self.destroyIndex = try Self.symbol(
                "cmux_nucleo_index_destroy",
                from: handle,
                as: DestroyIndex.self
            )
            self.searchIndex = try Self.symbol(
                "cmux_nucleo_index_search",
                from: handle,
                as: SearchIndex.self
            )
            self.version = try Self.symbol(
                "cmux_nucleo_ffi_version",
                from: handle,
                as: Version.self
            )
        }

        deinit {
            dlclose(handle)
        }

        private static func symbol<T>(_ name: String, from handle: UnsafeMutableRawPointer, as _: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else {
                throw NSError(
                    domain: "CommandPaletteNucleoFFITests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "dlsym(\(name)) failed: \(dlerrorText())"]
                )
            }
            return unsafeBitCast(pointer, to: T.self)
        }

        private static func dlerrorText() -> String {
            guard let error = dlerror() else { return "unknown error" }
            return String(cString: error)
        }
    }

    private final class NucleoIndex {
        let library: NucleoLibrary
        let pointer: OpaquePointer
        let entries: [FixtureEntry]

        init(library: NucleoLibrary, entries: [FixtureEntry]) throws {
            self.library = library
            self.entries = entries

            var blob: [UInt8] = []
            var spans: [FFICandidateSpan] = []
            blob.reserveCapacity(entries.reduce(0) { total, entry in
                total + entry.title.utf8.count + entry.searchableTexts.reduce(0) { $0 + $1.utf8.count + 1 }
            })
            spans.reserveCapacity(entries.count)

            for entry in entries {
                let titleOffset = blob.count
                blob.append(contentsOf: entry.title.utf8)
                let titleLength = blob.count - titleOffset

                let searchOffset = blob.count
                blob.append(contentsOf: entry.searchableTexts.joined(separator: "\n").utf8)
                let searchLength = blob.count - searchOffset

                spans.append(
                    FFICandidateSpan(
                        titleOffset: titleOffset,
                        titleLength: titleLength,
                        searchOffset: searchOffset,
                        searchLength: searchLength,
                        rank: Int32(entry.rank)
                    )
                )
            }

            guard let pointer = blob.withUnsafeBufferPointer({ blobBuffer in
                spans.withUnsafeBufferPointer { spanBuffer in
                    library.createIndex(
                        blobBuffer.baseAddress,
                        blobBuffer.count,
                        UnsafeRawPointer(spanBuffer.baseAddress),
                        spanBuffer.count
                    )
                }
            }) else {
                throw NSError(
                    domain: "CommandPaletteNucleoFFITests",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "cmux_nucleo_index_create returned null"]
                )
            }
            self.pointer = pointer
        }

        deinit {
            library.destroyIndex(pointer)
        }

        func search(query: String, limit: Int) throws -> [NucleoResult] {
            var matches = Array(
                repeating: FFIMatch(index: 0, score: 0, rank: 0),
                count: max(1, limit)
            )
            var count = 0
            let queryBytes = Array(query.utf8)
            let status = queryBytes.withUnsafeBufferPointer { queryBuffer in
                matches.withUnsafeMutableBufferPointer { matchBuffer in
                    library.searchIndex(
                        pointer,
                        queryBuffer.baseAddress,
                        queryBuffer.count,
                        limit,
                        UnsafeMutableRawPointer(matchBuffer.baseAddress),
                        matchBuffer.count,
                        &count
                    )
                }
            }
            guard status == 0 else {
                throw NSError(
                    domain: "CommandPaletteNucleoFFITests",
                    code: Int(status),
                    userInfo: [NSLocalizedDescriptionKey: "cmux_nucleo_index_search failed with \(status)"]
                )
            }

            return matches.prefix(count).compactMap { match in
                guard entries.indices.contains(match.index) else { return nil }
                let entry = entries[match.index]
                return NucleoResult(
                    id: entry.id,
                    rank: Int(match.rank),
                    title: entry.title,
                    score: match.score
                )
            }
        }
    }

    func testNucleoFFIPrefersOpenFolderForOpenFolderQuery() throws {
        let library = try NucleoLibrary()
        XCTAssertEqual(library.version(), 2)
        let entries = makeOpenFolderEntries()
        let index = try NucleoIndex(library: library, entries: entries)

        let resultIDs = try index.search(query: "open folder", limit: 4).map(\.id)

        XCTAssertEqual(
            Array(resultIDs.prefix(2)),
            ["palette.openFolder", "palette.openFolderInVSCodeInline"]
        )
    }

    func testNucleoFFIPrefersTitleInitialismOverCompactInWordMatch() throws {
        let library = try NucleoLibrary()
        let entries = makeInitialismWorkspaceEntries()
        let index = try NucleoIndex(library: library, entries: entries)

        let resultIDs = try index.search(query: "ims", limit: 5).map(\.id)

        XCTAssertEqual(resultIDs.first, "workspace.indigoMarkdownStudio")
    }

    func testNucleoFFIHandlesEmptyQuery() throws {
        let library = try NucleoLibrary()
        let entries = makeOpenFolderEntries()
        let index = try NucleoIndex(library: library, entries: entries)

        let resultIDs = try index.search(query: "", limit: 3).map(\.id)

        XCTAssertEqual(resultIDs, ["palette.newWorkspace", "palette.newWindow", "palette.openFolder"])
    }

    func testNucleoFFIFindsDeepWorkspaceMatch() throws {
        let library = try NucleoLibrary()
        let entries = makeLargeWorkspaceSwitcherEntries(count: 5_000)
        let index = try NucleoIndex(library: library, entries: entries)

        let results = try index.search(query: "workspace 4913", limit: 10)

        XCTAssertEqual(results.first?.id, "workspace.large.4913")
        XCTAssertLessThanOrEqual(results.count, 10)
    }

    func testProductionNucleoSearchIndexFindsCommandPaletteCommands() throws {
        let entries = makeOpenFolderEntries()
        let corpus = searchCorpus(entries: entries)
        guard let index = CommandPaletteNucleoSearchIndex(entries: corpus) else {
            throw XCTSkip("Build the nucleo FFI dylib before running production wrapper tests")
        }

        let resultIDs = index.search(
            query: "open folder",
            resultLimit: 4,
            historyBoost: { _, _ in 0 }
        )?.map(\.payload)

        XCTAssertEqual(
            Array((resultIDs ?? []).prefix(2)),
            ["palette.openFolder", "palette.openFolderInVSCodeInline"]
        )
    }

    func testAppBundleContainsNucleoSearchLibrary() throws {
        let privateFrameworksPath = try XCTUnwrap(Bundle.main.privateFrameworksPath)
        let libraryPath = URL(fileURLWithPath: privateFrameworksPath)
            .appendingPathComponent("libcmux_command_palette_nucleo_ffi.dylib")
            .path

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: libraryPath),
            "Expected bundled nucleo search library at \(libraryPath)"
        )
    }

    func testProductionNucleoSearchIndexAppliesHistoryBoostBeforeLimiting() throws {
        let entries = makeOpenFolderEntries()
        let corpus = searchCorpus(entries: entries)
        guard let index = CommandPaletteNucleoSearchIndex(entries: corpus) else {
            throw XCTSkip("Build the nucleo FFI dylib before running production wrapper tests")
        }

        let results = index.search(
            query: "",
            resultLimit: 1,
            historyBoost: { commandID, _ in commandID == "palette.openFolder" ? 600 : 0 }
        )

        XCTAssertEqual(results?.map(\.payload), ["palette.openFolder"])
    }

    func testNucleoFFILargeWorkspacePerformanceAndCorrectnessComparison() throws {
        let library = try NucleoLibrary()
        let entries = makeLargeWorkspaceSwitcherEntries(count: 800)
        let corpus = searchCorpus(entries: entries)
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

        var index: NucleoIndex?
        let buildMs = benchmarkElapsedMs {
            index = try? NucleoIndex(library: library, entries: entries)
        }
        let nucleoIndex = try XCTUnwrap(index)

        for query in queries.prefix(8) {
            _ = optimizedResults(corpus: corpus, query: query, resultLimit: 100)
            _ = try nucleoIndex.search(query: query, limit: 100)
        }

        let optimizedMs = benchmarkElapsedMs {
            for query in queries {
                _ = optimizedResults(corpus: corpus, query: query, resultLimit: 100)
            }
        }
        let nucleoMs = benchmarkElapsedMs {
            for query in queries {
                _ = try? nucleoIndex.search(query: query, limit: 100)
            }
        }

        let comparison = try correctnessComparison(
            corpus: corpus,
            queries: Array(Set(queries)).sorted(),
            index: nucleoIndex,
            resultLimit: 20
        )
        print(String(
            format: "BENCH cmd+p nucleo-ffi large-workspaces build=%.2fms swiftOptimized=%.2fms nucleo=%.2fms top1Agreement=%d/%d meanTop10Overlap=%.2f",
            buildMs,
            optimizedMs,
            nucleoMs,
            comparison.top1Agreement,
            comparison.queryCount,
            comparison.meanTop10Overlap
        ))
        if !comparison.top1Mismatches.isEmpty {
            print("CHECK cmd+p nucleo-ffi top1Mismatches \(comparison.top1Mismatches.joined(separator: "; "))")
        }

        XCTAssertGreaterThan(comparison.queryCount, 0)
        XCTAssertGreaterThan(nucleoMs, 0)
    }

    func testNucleoFFIFastTypingFrameBudgetComparison() throws {
        let library = try NucleoLibrary()
        let entries = makeLargeWorkspaceSwitcherEntries(count: 800)
        let previewEntries = Array(entries.prefix(128))
        let corpus = searchCorpus(entries: entries)
        let previewCorpus = searchCorpus(entries: previewEntries)
        let fullIndex = try NucleoIndex(library: library, entries: entries)
        let previewIndex = try NucleoIndex(library: library, entries: previewEntries)
        let queries = repeatedQueries(
            fastTypingPrefixes("cmd-p-search") + fastTypingPrefixes("palette latency"),
            repetitions: 2
        )

        for query in queries.prefix(8) {
            _ = optimizedResults(corpus: corpus, query: query, resultLimit: 100)
            _ = optimizedResults(corpus: previewCorpus, query: query, resultLimit: 48)
            _ = try fullIndex.search(query: query, limit: 100)
            _ = try previewIndex.search(query: query, limit: 48)
        }

        var swiftFullDurationsMs: [Double] = []
        var swiftPreviewDurationsMs: [Double] = []
        var nucleoFullDurationsMs: [Double] = []
        var nucleoPreviewDurationsMs: [Double] = []
        swiftFullDurationsMs.reserveCapacity(queries.count)
        swiftPreviewDurationsMs.reserveCapacity(queries.count)
        nucleoFullDurationsMs.reserveCapacity(queries.count)
        nucleoPreviewDurationsMs.reserveCapacity(queries.count)

        for query in queries {
            swiftFullDurationsMs.append(
                benchmarkElapsedMs {
                    _ = optimizedResults(corpus: corpus, query: query, resultLimit: 100)
                }
            )
            swiftPreviewDurationsMs.append(
                benchmarkElapsedMs {
                    _ = optimizedResults(corpus: previewCorpus, query: query, resultLimit: 48)
                }
            )
            nucleoFullDurationsMs.append(
                benchmarkElapsedMs {
                    _ = try? fullIndex.search(query: query, limit: 100)
                }
            )
            nucleoPreviewDurationsMs.append(
                benchmarkElapsedMs {
                    _ = try? previewIndex.search(query: query, limit: 48)
                }
            )
        }

        print(String(
            format: "BENCH cmd+p nucleo-ffi fast-typing swiftFull=%.2fms swiftPreview=%.2fms nucleoFull=%.2fms nucleoPreview=%.2fms maxSwiftFull=%.2fms maxSwiftPreview=%.2fms maxNucleoFull=%.2fms maxNucleoPreview=%.2fms swiftFullDroppedFrames=%d swiftPreviewDroppedFrames=%d nucleoFullDroppedFrames=%d nucleoPreviewDroppedFrames=%d",
            swiftFullDurationsMs.reduce(0, +),
            swiftPreviewDurationsMs.reduce(0, +),
            nucleoFullDurationsMs.reduce(0, +),
            nucleoPreviewDurationsMs.reduce(0, +),
            swiftFullDurationsMs.max() ?? 0,
            swiftPreviewDurationsMs.max() ?? 0,
            nucleoFullDurationsMs.max() ?? 0,
            nucleoPreviewDurationsMs.max() ?? 0,
            estimatedDroppedFrames(for: swiftFullDurationsMs),
            estimatedDroppedFrames(for: swiftPreviewDurationsMs),
            estimatedDroppedFrames(for: nucleoFullDurationsMs),
            estimatedDroppedFrames(for: nucleoPreviewDurationsMs)
        ))

        XCTAssertLessThanOrEqual(
            estimatedDroppedFrames(for: nucleoPreviewDurationsMs),
            estimatedDroppedFrames(for: nucleoFullDurationsMs)
        )
    }

    func testNucleoFFIEdgeCaseTypingFrameBudgetComparison() throws {
        let entries = makeEdgeCasePaletteEntries(generatedWorkspaceCount: 2_000)
        let corpus = searchCorpus(entries: entries)
        var index: CommandPaletteNucleoSearchIndex<String>?
        let buildMs = benchmarkElapsedMs {
            index = CommandPaletteNucleoSearchIndex(entries: corpus)
        }
        let productionIndex = try XCTUnwrap(index)
        let queries = repeatedQueries(edgeCaseTypingQueries(), repetitions: 2)

        for query in queries.prefix(16) {
            _ = optimizedResults(corpus: corpus, query: query, resultLimit: 100)
            _ = productionIndex.search(query: query, resultLimit: 100)
        }

        var swiftDurationsMs: [Double] = []
        var nucleoDurationsMs: [Double] = []
        var boostedNucleoDurationsMs: [Double] = []
        swiftDurationsMs.reserveCapacity(queries.count)
        nucleoDurationsMs.reserveCapacity(queries.count)
        boostedNucleoDurationsMs.reserveCapacity(queries.count)

        for query in queries {
            swiftDurationsMs.append(
                benchmarkElapsedMs {
                    _ = optimizedResults(corpus: corpus, query: query, resultLimit: 100)
                }
            )
            nucleoDurationsMs.append(
                benchmarkElapsedMs {
                    _ = productionIndex.search(query: query, resultLimit: 100)
                }
            )
            boostedNucleoDurationsMs.append(
                benchmarkElapsedMs {
                    _ = productionIndex.search(
                        query: query,
                        resultLimit: 100,
                        historyBoost: { commandID, queryIsEmpty in
                            if commandID == "palette.markWorkspaceUnread" {
                                return queryIsEmpty ? 300 : 120
                            }
                            return 0
                        }
                    )
                }
            )
        }

        let expectedTopResults = [
            ("ims", "workspace.indigoMarkdownStudio"),
            ("wunr", "palette.markWorkspaceUnread"),
            ("open folder", "palette.openFolder"),
            ("workspace 1901", "workspace.large.1901"),
            ("cafe", "workspace.cafeUnicodeNotes"),
        ]
        for (query, expectedID) in expectedTopResults {
            XCTAssertEqual(
                productionIndex.search(query: query, resultLimit: 10)?.first?.payload,
                expectedID,
                "Unexpected top result for \(query)"
            )
        }

        print(String(
            format: "BENCH cmd+p nucleo-ffi edge-typing entries=%d queries=%d build=%.2fms swift=%.2fms nucleo=%.2fms boostedNucleo=%.2fms maxSwift=%.2fms p95Swift=%.2fms maxNucleo=%.2fms p95Nucleo=%.2fms maxBoostedNucleo=%.2fms p95BoostedNucleo=%.2fms swiftDroppedFrames=%d nucleoDroppedFrames=%d boostedNucleoDroppedFrames=%d",
            entries.count,
            queries.count,
            buildMs,
            swiftDurationsMs.reduce(0, +),
            nucleoDurationsMs.reduce(0, +),
            boostedNucleoDurationsMs.reduce(0, +),
            swiftDurationsMs.max() ?? 0,
            percentile(swiftDurationsMs, percentile: 0.95),
            nucleoDurationsMs.max() ?? 0,
            percentile(nucleoDurationsMs, percentile: 0.95),
            boostedNucleoDurationsMs.max() ?? 0,
            percentile(boostedNucleoDurationsMs, percentile: 0.95),
            estimatedDroppedFrames(for: swiftDurationsMs),
            estimatedDroppedFrames(for: nucleoDurationsMs),
            estimatedDroppedFrames(for: boostedNucleoDurationsMs)
        ))

        XCTAssertLessThanOrEqual(
            estimatedDroppedFrames(for: nucleoDurationsMs),
            estimatedDroppedFrames(for: swiftDurationsMs)
        )
    }

    func testNucleoFFICallOverheadBenchmark() throws {
        let library = try NucleoLibrary()
        let entries = makeLargeWorkspaceSwitcherEntries(count: 800)
        let corpus = searchCorpus(entries: entries)
        let rawIndex = try NucleoIndex(library: library, entries: entries)
        let productionIndex = try XCTUnwrap(CommandPaletteNucleoSearchIndex(entries: corpus))
        let noopIterations = 50_000
        let searchIterations = 200
        let queryBytes = Array("cmd-p-search".utf8)
        var ffiNoopFailures = 0

        var outCount = 0
        let ffiNoopMs = benchmarkElapsedMs {
            for _ in 0..<noopIterations {
                let status = queryBytes.withUnsafeBufferPointer { queryBuffer in
                    library.searchIndex(
                        rawIndex.pointer,
                        queryBuffer.baseAddress,
                        queryBuffer.count,
                        0,
                        nil,
                        0,
                        &outCount
                    )
                }
                if status != 0 { ffiNoopFailures += 1 }
            }
        }

        let rawSearchMs = benchmarkElapsedMs {
            for _ in 0..<searchIterations {
                _ = try? rawIndex.search(query: "cmd-p-search", limit: 100)
            }
        }
        let productionNoHistoryMs = benchmarkElapsedMs {
            for _ in 0..<searchIterations {
                _ = productionIndex.search(query: "cmd-p-search", resultLimit: 100)
            }
        }
        let productionZeroBoostClosureMs = benchmarkElapsedMs {
            for _ in 0..<searchIterations {
                _ = productionIndex.search(
                    query: "cmd-p-search",
                    resultLimit: 100,
                    historyBoost: { _, _ in 0 }
                )
            }
        }

        print(String(
            format: "BENCH cmd+p nucleo-ffi overhead noopCalls=%d noopTotal=%.2fms noopPerCall=%.3fus rawSearchPerCall=%.3fms prodNoHistoryPerCall=%.3fms prodZeroBoostClosurePerCall=%.3fms",
            noopIterations,
            ffiNoopMs,
            (ffiNoopMs * 1_000.0) / Double(noopIterations),
            rawSearchMs / Double(searchIterations),
            productionNoHistoryMs / Double(searchIterations),
            productionZeroBoostClosureMs / Double(searchIterations)
        ))

        XCTAssertEqual(ffiNoopFailures, 0)
    }

    private func makeOpenFolderEntries() -> [FixtureEntry] {
        [
            FixtureEntry(
                id: "palette.newWorkspace",
                rank: 0,
                title: "New Workspace",
                searchableTexts: ["New Workspace", "Workspace", "create", "new", "workspace"]
            ),
            FixtureEntry(
                id: "palette.newWindow",
                rank: 1,
                title: "New Window",
                searchableTexts: ["New Window", "Window", "create", "new", "window"]
            ),
            FixtureEntry(
                id: "palette.openFolder",
                rank: 2,
                title: "Open Folder...",
                searchableTexts: ["Open Folder...", "Workspace", "open", "folder", "repository", "project", "directory"]
            ),
            FixtureEntry(
                id: "palette.openFolderInVSCodeInline",
                rank: 3,
                title: "Open Folder in VS Code (Inline)...",
                searchableTexts: [
                    "Open Folder in VS Code (Inline)...",
                    "VS Code Inline",
                    "open",
                    "folder",
                    "directory",
                    "project",
                    "vs",
                    "code",
                    "inline",
                    "editor",
                    "browser",
                ]
            ),
        ]
    }

    private func makeInitialismWorkspaceEntries() -> [FixtureEntry] {
        [
            FixtureEntry(
                id: "workspace.yarrowImageSorter",
                rank: 0,
                title: "Yarrow Image Sorter",
                searchableTexts: ["Yarrow Image Sorter", "Workspace", "workspace", "switch", "go"]
            ),
            FixtureEntry(
                id: "workspace.indigoMarkdownStudio",
                rank: 1,
                title: "Indigo Markdown Studio",
                searchableTexts: ["Indigo Markdown Studio", "Workspace", "workspace", "switch", "go"]
            ),
            FixtureEntry(
                id: "workspace.ivoryMeetingNotes",
                rank: 2,
                title: "Ivory Meeting Notes",
                searchableTexts: ["Ivory Meeting Notes", "Workspace", "workspace", "switch", "go"]
            ),
            FixtureEntry(
                id: "workspace.graniteMusicVault",
                rank: 3,
                title: "Granite Music Vault",
                searchableTexts: ["Granite Music Vault", "Workspace", "workspace", "switch", "go"]
            ),
            FixtureEntry(
                id: "workspace.nimbusInvoiceDesk",
                rank: 4,
                title: "Nimbus Invoice Desk",
                searchableTexts: ["Nimbus Invoice Desk", "Workspace", "workspace", "switch", "go"]
            ),
        ]
    }

    private func makeEdgeCasePaletteEntries(generatedWorkspaceCount: Int) -> [FixtureEntry] {
        var entries = makeOpenFolderEntries()
        entries.append(
            FixtureEntry(
                id: "palette.markWorkspaceUnread",
                rank: entries.count,
                title: "Mark Workspace as Unread",
                searchableTexts: [
                    "Mark Workspace as Unread",
                    "Workspace",
                    "mark",
                    "unread",
                    "notification",
                ]
            )
        )
        entries.append(contentsOf: makeInitialismWorkspaceEntries().map { entry in
            FixtureEntry(
                id: entry.id,
                rank: entries.count + entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        })
        entries.append(
            FixtureEntry(
                id: "workspace.cafeUnicodeNotes",
                rank: entries.count,
                title: "Café Unicode Notes",
                searchableTexts: [
                    "Café Unicode Notes",
                    "Cafe Unicode Notes",
                    "cafe",
                    "unicode",
                    "workspace",
                ]
            )
        )

        let generatedRankOffset = entries.count
        entries.append(contentsOf: makeLargeWorkspaceSwitcherEntries(count: generatedWorkspaceCount).map { entry in
            FixtureEntry(
                id: entry.id,
                rank: generatedRankOffset + entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        })
        return entries
    }

    private func makeLargeWorkspaceSwitcherEntries(count: Int) -> [FixtureEntry] {
        (0..<count).map { index in
            let projectSlug = "project-\(index)-cmd-p-search-performance"
            let worktreeSlug = "feature-\(index)-palette-latency"
            let title = "Workspace \(index) \(projectSlug)"
            let keywords = CommandPaletteSwitcherSearchIndexer.keywords(
                baseKeywords: [
                    "workspace",
                    "switch",
                    "go",
                    "open",
                    title,
                    "Window \((index % 4) + 1)",
                ],
                metadata: CommandPaletteSwitcherSearchMetadata(
                    directories: [
                        "/Users/example/dev/cmuxterm-hq/worktrees/\(worktreeSlug)",
                        "/Users/example/dev/cmuxterm-hq/worktrees/\(worktreeSlug)/repo",
                    ],
                    branches: [
                        "feature/palette-latency-\(index)",
                        "task/cmd-p-search-\(index % 17)",
                    ],
                    ports: [
                        3000 + (index % 50),
                        4200 + (index % 25),
                        9200 + (index % 10),
                    ],
                    description: "Palette performance fixture \(index) for \(projectSlug)"
                ),
                detail: .workspace
            )
            return FixtureEntry(
                id: "workspace.large.\(index)",
                rank: index,
                title: title,
                searchableTexts: [title, "Workspace"] + keywords
            )
        }
    }

    private func searchCorpus(entries: [FixtureEntry]) -> [CommandPaletteSearchCorpusEntry<String>] {
        entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
    }

    private func optimizedResults(
        corpus: [CommandPaletteSearchCorpusEntry<String>],
        query: String,
        resultLimit: Int
    ) -> [FixtureResult] {
        CommandPaletteSearchEngine.search(
            entries: corpus,
            query: query,
            resultLimit: resultLimit
        ) { _, _ in 0 }
            .map {
                FixtureResult(
                    id: $0.payload,
                    rank: $0.rank,
                    title: $0.title,
                    score: $0.score
                )
            }
    }

    private func optimizedResults(
        entries: [FixtureEntry],
        query: String,
        resultLimit: Int
    ) -> [FixtureResult] {
        optimizedResults(corpus: searchCorpus(entries: entries), query: query, resultLimit: resultLimit)
    }

    private func correctnessComparison(
        corpus: [CommandPaletteSearchCorpusEntry<String>],
        queries: [String],
        index: NucleoIndex,
        resultLimit: Int
    ) throws -> (
        queryCount: Int,
        top1Agreement: Int,
        meanTop10Overlap: Double,
        top1Mismatches: [String]
    ) {
        var top1Agreement = 0
        var totalTop10Overlap = 0.0
        var top1Mismatches: [String] = []

        for query in queries {
            let swiftIDs = optimizedResults(corpus: corpus, query: query, resultLimit: resultLimit)
                .map(\.id)
            let nucleoIDs = try index.search(query: query, limit: resultLimit).map(\.id)
            if swiftIDs.first == nucleoIDs.first {
                top1Agreement += 1
            } else {
                let swiftTop = swiftIDs.first ?? "<none>"
                let nucleoTop = nucleoIDs.first ?? "<none>"
                top1Mismatches.append("\(query): swift=\(swiftTop) nucleo=\(nucleoTop)")
            }

            let swiftTop10 = Set(swiftIDs.prefix(10))
            let nucleoTop10 = Set(nucleoIDs.prefix(10))
            if !swiftTop10.isEmpty || !nucleoTop10.isEmpty {
                totalTop10Overlap += Double(swiftTop10.intersection(nucleoTop10).count) / 10.0
            }
        }

        return (
            queryCount: queries.count,
            top1Agreement: top1Agreement,
            meanTop10Overlap: queries.isEmpty ? 0 : totalTop10Overlap / Double(queries.count),
            top1Mismatches: top1Mismatches
        )
    }

    private func fastTypingPrefixes(_ text: String) -> [String] {
        text.indices.map { index in
            String(text[...index])
        }
    }

    private func edgeCaseTypingQueries() -> [String] {
        var queries: [String] = []
        for text in [
            "ims",
            "wunr",
            "open folder",
            "workspace 1901",
            "feature/palette-latency-177",
            "project-1999",
            "cmd-p-search",
            "cafe unicode",
            "zzzzzzzz",
        ] {
            queries.append(contentsOf: fastTypingPrefixes(text))
        }
        queries.append(contentsOf: [
            "",
            "   ",
            "  OPEN   FOLDER  ",
            "Window 3",
            "3007",
            "4207",
            "9207",
            "task/cmd-p-search-7",
            "feature palette latency",
            "project 42 cmd p",
            "workspace/branch:177",
            "café",
            "Cafe",
            "no-match-query",
        ])
        return queries
    }

    private func estimatedDroppedFrames(
        for queryDurationsMs: [Double],
        frameBudgetMs: Double = 1000.0 / 60.0
    ) -> Int {
        queryDurationsMs.reduce(0) { total, durationMs in
            total + max(0, Int(ceil(durationMs / frameBudgetMs)) - 1)
        }
    }

    private func benchmarkElapsedMs(operation: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        operation()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        return Double(elapsed) / 1_000_000
    }

    private func percentile(_ values: [Double], percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let clampedPercentile = min(1, max(0, percentile))
        let index = Int((Double(sorted.count - 1) * clampedPercentile).rounded())
        return sorted[index]
    }

    private func repeatedQueries(_ baseQueries: [String], repetitions: Int) -> [String] {
        Array(repeating: baseQueries, count: repetitions).flatMap { $0 }
    }
}
