import Foundation
import Observation

/// Loads, parses and renders a diff. Parsing, syntax highlighting and word
/// diffs run on a detached task; the main actor only swaps in finished rows.
@MainActor
@Observable
final class DiffViewModel {
    enum Phase: Equatable {
        case loading
        case failed(String)
        case loaded
    }

    /// Files above this many diff lines start collapsed behind "Load diff".
    nonisolated static let largeFileLines = 2000

    private(set) var phase: Phase = .loading
    /// The Mac cut the diff; `shownLines` is how many diff lines arrived.
    private(set) var truncated = false
    private(set) var shownLines = 0
    private(set) var files: [DiffFile] = []
    private(set) var rendered: [Int: RenderedDiffFile] = [:]
    private(set) var collapsed: Set<Int> = []
    private(set) var viewed: Set<Int> = []
    private(set) var expanding: Set<Int> = []
    private var largeLoaded: Set<Int> = []
    private var expandedGaps: [Int: Set<Int>] = [:]
    private var contents: [Int: [String]] = [:]

    private let loader: @Sendable () async throws -> DiffPayload
    let contextLoader: (@Sendable (String) async throws -> String)?
    private var generation = 0

    init(loader: @escaping @Sendable () async throws -> DiffPayload, contextLoader: (@Sendable (String) async throws -> String)?) {
        self.loader = loader
        self.contextLoader = contextLoader
    }

    var totalAdditions: Int { files.totalAdditions }
    var totalDeletions: Int { files.totalDeletions }

    func isLarge(_ file: DiffFile) -> Bool {
        file.lineCount > Self.largeFileLines && !largeLoaded.contains(file.index)
    }

    func isCollapsed(_ file: DiffFile) -> Bool {
        collapsed.contains(file.index) || isLarge(file)
    }

    /// Maximum display columns across expanded files (no-wrap width).
    var maxColumns: Int {
        files.reduce(0) { result, file in
            guard !isCollapsed(file), let rendered = rendered[file.index] else { return result }
            return max(result, rendered.maxColumns)
        }
    }

    var maxNumberDigits: Int {
        rendered.values.reduce(1) { max($0, $1.numberDigits) }
    }

    func load() async {
        generation += 1
        let token = generation
        resolver?.cancel()
        resolver = nil
        if files.isEmpty { phase = .loading }
        do {
            let payload = try await loader()
            let text = payload.text
            let canExpand = contextLoader != nil
            let result = await Task.detached(priority: .userInitiated) { () -> ([DiffFile], [Int: RenderedDiffFile]) in
                let files = UnifiedDiffParser.parse(text)
                var rendered: [Int: RenderedDiffFile] = [:]
                for file in files where file.lineCount <= DiffViewModel.largeFileLines {
                    rendered[file.index] = DiffRenderer.render(file, contents: nil, expanded: [], canExpand: canExpand)
                }
                return (files, rendered)
            }.value
            guard token == generation else { return }
            files = result.0
            truncated = payload.truncated
            shownLines = payload.truncated ? DiffPayload.lineCount(text) : 0
            rendered = result.1
            collapsed = []
            viewed = []
            largeLoaded = []
            expandedGaps = [:]
            contents = [:]
            phase = .loaded
            // In the background: a refresh doesn't wait for these reads.
            resolver = Task { [weak self] in await self?.resolveTrailingGaps(token: token) }
        } catch is CancellationError {
            return
        } catch {
            guard token == generation else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    func toggleCollapsed(_ file: DiffFile) {
        if isLarge(file) { return }
        if collapsed.contains(file.index) { collapsed.remove(file.index) } else { collapsed.insert(file.index) }
    }

    func setAllCollapsed(_ value: Bool) {
        collapsed = value ? Set(files.map(\.index)) : viewed
    }

    /// Marking a file viewed collapses it, like GitHub.
    func toggleViewed(_ file: DiffFile) {
        if viewed.contains(file.index) {
            viewed.remove(file.index)
            collapsed.remove(file.index)
        } else {
            viewed.insert(file.index)
            collapsed.insert(file.index)
        }
    }

    func loadLarge(_ file: DiffFile) async {
        largeLoaded.insert(file.index)
        collapsed.remove(file.index)
        guard rendered[file.index] == nil else { return }
        await rerender(file)
    }

    /// A last hunk with a full 3 lines of trailing context may or may not
    /// end the file. Read the first few such files so "Expand remaining
    /// lines" only shows when there is something left (GitHub knows the
    /// blob length; we read the file once and reuse it for expanding).
    private func resolveTrailingGaps(token: Int) async {
        guard let contextLoader else { return }
        let ambiguous = files.filter { file in
            guard rendered[file.index] != nil, file.status != .deleted, !file.isBinary,
                  let last = file.hunks.last else { return false }
            return !DiffRenderer.reachesEndOfFile(file, last: last)
        }
        for file in ambiguous.prefix(Self.trailingGapReads) {
            guard !Task.isCancelled, token == generation else { return }
            // An expand of this file reads it too; let that one win.
            guard contents[file.index] == nil, !expanding.contains(file.index),
                  let text = try? await contextLoader(file.path) else { continue }
            let lines = await Task.detached { DiffRenderer.contentLines(text) }.value
            guard !Task.isCancelled, token == generation, contents[file.index] == nil else { return }
            contents[file.index] = lines
            await rerender(file, token: token)
        }
    }

    static let trailingGapReads = 12
    private var resolver: Task<Void, Never>?

    /// Expands the hidden lines before hunk `gap` (or after the last hunk).
    func expand(_ file: DiffFile, gap: Int) async {
        guard let contextLoader, !expanding.contains(file.index) else { return }
        let token = generation
        expanding.insert(file.index)
        defer { expanding.remove(file.index) }
        if contents[file.index] == nil {
            do {
                let text = try await contextLoader(file.path)
                let lines = await Task.detached { DiffRenderer.contentLines(text) }.value
                // A reload since then may have put another file at this index.
                guard token == generation else { return }
                contents[file.index] = lines
            } catch {
                return
            }
        }
        expandedGaps[file.index, default: []].insert(gap)
        await rerender(file, token: token)
    }

    /// `token`: the load this render belongs to; a newer load drops it.
    private func rerender(_ file: DiffFile, token: Int? = nil) async {
        let token = token ?? generation
        let lines = contents[file.index]
        let gaps = expandedGaps[file.index] ?? []
        let canExpand = contextLoader != nil
        let result = await Task.detached(priority: .userInitiated) {
            DiffRenderer.render(file, contents: lines, expanded: gaps, canExpand: canExpand)
        }.value
        guard token == generation else { return }
        rendered[file.index] = result
    }
}
