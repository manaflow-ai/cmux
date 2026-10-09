import CmuxMobileWire
import Foundation
import Observation

/// One folder of a workspace's files (`files.list`), paged by `next`.
/// The first screen resolves the workspace's folder from `files.roots`.
@MainActor
@Observable
public final class FileBrowserModel {
    public let target: ViewerTarget
    public private(set) var path: String?
    public private(set) var title: String
    public private(set) var entries: [FilesListEntry] = []
    public private(set) var next: String?
    public private(set) var phase: ViewerPhase = .idle
    @ObservationIgnored private let source: any ViewerContentSource
    @ObservationIgnored private var loadingMore = false

    /// `path` nil: the workspace's folder.
    public init(target: ViewerTarget, source: any ViewerContentSource, path: String? = nil, title: String? = nil) {
        self.target = target
        self.source = source
        self.path = path
        self.title = title ?? target.title
    }

    public var hasMore: Bool { next != nil }

    /// New Folder, Rename and Delete; nil where the source cannot write (Macs).
    public var operations: (any ViewerFileOperations)? { source as? any ViewerFileOperations }

    /// Creates a folder in this folder, then reloads. Nil on success.
    public func makeFolder(named raw: String) async -> ViewerSourceError? {
        guard let name = ViewerFileName(raw) else { return .failed("invalid name") }
        guard let operations, let path else { return .forbidden }
        return await write { try await operations.makeDirectory(host: self.target.hostID, path: Self.join(path, name.value)) }
    }

    /// Renames an entry of this folder, then reloads. Nil on success.
    public func rename(_ entry: FilesListEntry, to raw: String) async -> ViewerSourceError? {
        guard let name = ViewerFileName(raw) else { return .failed("invalid name") }
        guard let operations, let path else { return .forbidden }
        guard name.value != entry.name else { return nil }
        return await write {
            try await operations.rename(host: self.target.hostID, from: Self.join(path, entry.name), to: Self.join(path, name.value))
        }
    }

    /// Deletes a file or an empty folder of this folder, then reloads. Nil on success.
    public func delete(_ entry: FilesListEntry) async -> ViewerSourceError? {
        guard let operations, let path else { return .forbidden }
        return await write {
            try await operations.remove(host: self.target.hostID, path: Self.join(path, entry.name), isDirectory: entry.kind == .dir)
        }
    }

    private func write(_ body: @escaping @MainActor () async throws -> Void) async -> ViewerSourceError? {
        do {
            try await body()
        } catch is CancellationError {
            return nil
        } catch {
            return error as? ViewerSourceError ?? .failed(String(describing: error))
        }
        await load()
        return nil
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    public func load() async {
        phase = .loading
        do {
            let folder: String
            if let path {
                folder = path
            } else {
                let root = try await source.workspaceRoot(for: target)
                folder = root.path
                path = root.path
                title = root.name
            }
            let page = try await source.list(host: target.hostID, path: folder, after: nil)
            entries = Self.sorted(page.entries)
            next = page.next
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error as? ViewerSourceError ?? .failed(String(describing: error)))
        }
    }

    /// The next page, once at a time.
    public func loadMore() async {
        guard let path, let after = next, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await source.list(host: target.hostID, path: path, after: after) else { return }
        entries = Self.sorted(entries + page.entries)
        next = page.next
    }

    public func childPath(_ entry: FilesListEntry) -> String? {
        guard let path else { return nil }
        return Self.join(path, entry.name)
    }

    /// Folders first, then by name in Finder order.
    static func sorted(_ entries: [FilesListEntry]) -> [FilesListEntry] {
        entries.sorted { a, b in
            if (a.kind == .dir) != (b.kind == .dir) { return a.kind == .dir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
