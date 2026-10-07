import CmuxMobileWire
import Foundation
import Observation

/// The changes screen of one workspace (c13-viewers.md section 4): the
/// repository status, the changed files of the chosen scope as a list or
/// tree, and each file's patch read on demand (one read per file, cached
/// until the scope changes or Refresh).
@MainActor
@Observable
public final class ChangesModel {
    public let target: ViewerTarget
    public private(set) var phase: ViewerPhase = .idle
    public private(set) var root: FilesRoot?
    public private(set) var status: GitStatusResult?
    public private(set) var diff: GitDiffResult?
    public private(set) var tree: [ChangedFileTreeRow] = []
    public private(set) var scope: GitDiffScope = .uncommitted
    public var showsTree = true
    @ObservationIgnored private let source: any ViewerContentSource
    @ObservationIgnored private var patches: [String: Task<DiffDocument, any Error>] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loading: Task<Void, Never>?

    public init(target: ViewerTarget, source: any ViewerContentSource) {
        self.target = target
        self.source = source
    }

    public var files: [GitChangedFile] { diff?.files ?? [] }

    /// Loads (or reloads) status and the file list of the current scope.
    public func load() async {
        loading?.cancel()
        generation += 1
        let generation = generation
        patches.values.forEach { $0.cancel() }
        patches = [:]
        phase = .loading
        let task = Task { [source, target, scope] in
            do {
                let root: FilesRoot
                if let known = self.root {
                    root = known
                } else {
                    root = try await source.workspaceRoot(for: target)
                }
                async let status = source.status(host: target.hostID, path: root.path)
                async let diff = source.diff(host: target.hostID, params: GitDiffParams(path: root.path, scope: scope))
                let (s, d) = try await (status, diff)
                guard generation == self.generation else { return }
                self.root = root
                self.status = s
                self.diff = d
                self.tree = ChangedFileTree(d.files).rows
                self.phase = .loaded
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.generation else { return }
                self.phase = .failed(error as? ViewerSourceError ?? .failed(String(describing: error)))
            }
        }
        loading = task
        await task.value
    }

    public func setScope(_ scope: GitDiffScope) async {
        guard scope != self.scope else { return }
        self.scope = scope
        diff = nil
        tree = []
        await load()
    }

    /// The parsed patch of `file`, read once per scope; binary files have none.
    public func document(for file: GitChangedFile) async throws -> DiffDocument {
        if file.isBinary { return DiffDocument(isBinary: true) }
        if let pending = patches[file.path] { return try await pending.value }
        guard let root else { throw ViewerSourceError.noWorkspaceFolder }
        let params = GitDiffParams(path: root.path, scope: scope, paths: [file.path], includePatch: true)
        let task = Task { [source, target] () throws -> DiffDocument in
            let result = try await source.diff(host: target.hostID, params: params)
            guard let changed = result.files.first(where: { $0.path == file.path }) else { return DiffDocument() }
            let patch = changed.patch ?? ""
            let truncated = changed.isPatchTruncated
            let binary = changed.isBinary
            return await Task.detached(priority: .userInitiated) {
                UnifiedDiffParser().parse(patch, truncated: truncated, binary: binary)
            }.value
        }
        patches[file.path] = task
        do {
            return try await task.value
        } catch {
            if patches[file.path] == task { patches[file.path] = nil }
            throw error
        }
    }

    /// The absolute Mac path of a changed file.
    public func absolutePath(of file: GitChangedFile) -> String? {
        guard let diff else { return nil }
        return diff.root.hasSuffix("/") ? diff.root + file.path : diff.root + "/" + file.path
    }
}
