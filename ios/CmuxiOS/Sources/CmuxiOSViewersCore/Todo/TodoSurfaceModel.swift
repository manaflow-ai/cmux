public import Foundation
public import Observation
import CmuxMobileWire

/// The workspace's todo list, read only (e4-compose.md 5): locates the file
/// in the workspace folder, downloads it through C4, and reports its task
/// progress. `load()` again is Refresh; nothing polls (no file change
/// stream exists).
@MainActor
@Observable
public final class TodoSurfaceModel {
    public enum State: Hashable, Sendable {
        case idle
        case loading
        /// The folder has none of the candidate files.
        case missing
        /// `url` is the local copy; `path` the Mac path.
        case loaded(url: URL, path: String, done: Int, total: Int)
        case failed(ViewerSourceError)
    }

    public let target: ViewerTarget
    public let locator: WorkspaceTodoLocator
    public private(set) var state: State = .idle
    @ObservationIgnored private let source: any ViewerContentSource
    @ObservationIgnored private var generation = 0

    public init(target: ViewerTarget, source: any ViewerContentSource, locator: WorkspaceTodoLocator = WorkspaceTodoLocator()) {
        self.target = target
        self.source = source
        self.locator = locator
    }

    public func load() async {
        generation += 1
        let current = generation
        state = .loading
        let next: State
        do {
            next = try await locate()
        } catch is CancellationError {
            return
        } catch {
            next = .failed(error as? ViewerSourceError ?? .failed(String(describing: error)))
        }
        // A newer Refresh owns the screen.
        if current == generation { state = next }
    }

    private func locate() async throws -> State {
        let root = try await source.workspaceRoot(for: target)
        var listings: [String: [FilesListEntry]] = ["": try await source.list(host: target.hostID, path: root.path, after: nil).entries]
        for folder in locator.subfolders {
            let name = folder.split(separator: "/").first.map(String.init) ?? folder
            guard listings[""]?.contains(where: { $0.name == name && $0.kind == .dir }) == true else { continue }
            listings[folder] = (try? await source.list(host: target.hostID, path: Self.join(root.path, folder), after: nil))?.entries
        }
        guard let found = locator.pick(from: listings) else { return .missing }
        let path = Self.join(root.path, found.path)
        let url = try await source.fetch(host: target.hostID, path: path, size: found.size)
        let text = String(decoding: (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data(), as: UTF8.self)
        let progress = MarkdownDocument(parsing: text).taskProgress
        return .loaded(url: url, path: path, done: progress.done, total: progress.total)
    }

    static func join(_ base: String, _ relative: String) -> String {
        base.hasSuffix("/") ? base + relative : base + "/" + relative
    }
}
