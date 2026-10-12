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
    private(set) var files: [DiffFile] = []
    private(set) var rendered: [Int: RenderedDiffFile] = [:]
    private(set) var collapsed: Set<Int> = []
    private(set) var viewed: Set<Int> = []
    private(set) var expanding: Set<Int> = []
    private var largeLoaded: Set<Int> = []
    private var expandedGaps: [Int: Set<Int>] = [:]
    private var contents: [Int: [String]] = [:]

    private let loader: @Sendable () async throws -> String
    let contextLoader: (@Sendable (String) async throws -> String)?
    private var generation = 0

    init(loader: @escaping @Sendable () async throws -> String, contextLoader: (@Sendable (String) async throws -> String)?) {
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
        if files.isEmpty { phase = .loading }
        do {
            let text = try await loader()
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
            rendered = result.1
            collapsed = []
            viewed = []
            largeLoaded = []
            expandedGaps = [:]
            contents = [:]
            phase = .loaded
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

    /// Expands the hidden lines before hunk `gap` (or after the last hunk).
    func expand(_ file: DiffFile, gap: Int) async {
        guard let contextLoader, !expanding.contains(file.index) else { return }
        expanding.insert(file.index)
        defer { expanding.remove(file.index) }
        if contents[file.index] == nil {
            do {
                let text = try await contextLoader(file.path)
                contents[file.index] = await Task.detached { DiffRenderer.contentLines(text) }.value
            } catch {
                return
            }
        }
        expandedGaps[file.index, default: []].insert(gap)
        await rerender(file)
    }

    private func rerender(_ file: DiffFile) async {
        let lines = contents[file.index]
        let gaps = expandedGaps[file.index] ?? []
        let canExpand = contextLoader != nil
        let result = await Task.detached(priority: .userInitiated) {
            DiffRenderer.render(file, contents: lines, expanded: gaps, canExpand: canExpand)
        }.value
        rendered[file.index] = result
    }
}
