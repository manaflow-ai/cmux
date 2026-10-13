import SwiftUI

/// Which changes a `DiffScreen` shows.
enum DiffScope: Hashable, Sendable {
    /// Unstaged working-tree changes (plus untracked files).
    case workingTree
    case staged
    /// Working tree against a base branch or ref.
    case base(String)

    var title: String {
        switch self {
        case .workingTree: String(localized: "Working Tree")
        case .staged: String(localized: "Staged")
        case .base(let ref): String(localized: "Against \(ref)")
        }
    }
}

/// The diff for a session's working directory with a native scope menu
/// (title menu: Working tree, Staged, Against base branch…). Push inside a
/// NavigationStack.
struct DiffScreen: View {
    let cwd: String
    let services: ServiceClient
    /// Limit the diff to one path (relative to `cwd`).
    var path: String?

    @State private var scope: DiffScope = .workingTree
    @State private var askingBase = false
    @State private var baseText = ""
    @State private var preview: DiffPreviewTarget?
    @AppStorage("diff.lastBase") private var lastBase = "main"

    init(cwd: String, services: ServiceClient, path: String? = nil, scope: DiffScope = .workingTree) {
        self.cwd = cwd
        self.services = services
        self.path = path
        _scope = State(initialValue: scope)
    }

    var body: some View {
        let cwd = cwd
        let services = services
        let path = path
        let scope = scope
        let contextLoader: (@Sendable (String) async throws -> String)? = scope == .staged ? nil : { @Sendable relative in
            let root = await services.repoRoot(cwd: cwd)
            let data = try await services.read(path: DiffPaths.join(root, relative)).data
            return String(decoding: data, as: UTF8.self)
        }
        DiffView(
            loader: { try await services.gitDiffText(cwd: cwd, path: path, scope: scope) },
            title: path.map { ($0 as NSString).lastPathComponent } ?? scope.title,
            contextLoader: contextLoader,
            onOpenFile: { relative in
                Task {
                    let root = await services.repoRoot(cwd: cwd)
                    preview = DiffPreviewTarget(path: DiffPaths.join(root, relative))
                }
            },
            images: (scope, { @Sendable source in
                switch source {
                case .git(let relative, let rev):
                    return try await services.gitShow(cwd: cwd, path: relative, rev: rev)
                case .disk(let relative):
                    let root = await services.repoRoot(cwd: cwd)
                    return try await services.read(path: DiffPaths.join(root, relative), limit: 16 << 20).data
                }
            })
        )
        .id(scope)
        .toolbarTitleMenu {
            Picker(String(localized: "Compare"), selection: $scope) {
                Label(DiffScope.workingTree.title, systemImage: "pencil.line").tag(DiffScope.workingTree)
                Label(DiffScope.staged.title, systemImage: "tray.full").tag(DiffScope.staged)
                if case .base(let ref) = scope {
                    Label(DiffScope.base(ref).title, systemImage: "arrow.triangle.branch").tag(scope)
                }
            }
            Button(String(localized: "Against Base Branch…"), systemImage: "arrow.triangle.branch") {
                baseText = lastBase
                askingBase = true
            }
        }
        .alert(String(localized: "Compare Against Branch"), isPresented: $askingBase) {
            TextField(String(localized: "Branch or ref"), text: $baseText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Compare")) {
                let ref = baseText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ref.isEmpty else { return }
                lastBase = ref
                self.scope = .base(ref)
            }
        } message: {
            Text(String(localized: "Shows the working tree compared with this branch, for example main or origin/main."))
        }
        .navigationDestination(item: $preview) { target in
            FilePreviewScreen(path: target.path, services: services)
        }
    }
}

/// A diff as the Mac sent it: the unified text and whether the Mac cut it
/// (its size cap, or too many untracked files).
struct DiffPayload: Sendable, Equatable {
    var text: String
    var truncated = false

    init(text: String, truncated: Bool = false) {
        self.text = text
        self.truncated = truncated
    }

    /// Lines in diff text (a cut last line counts).
    static func lineCount(_ text: String) -> Int {
        var count = 0
        for byte in text.utf8 where byte == 0x0A { count += 1 }
        if let last = text.utf8.last, last != 0x0A { count += 1 }
        return count
    }

    init(reply: JSONValue) {
        text = reply["diff"]?.string ?? reply["text"]?.string ?? reply.string ?? ""
        truncated = reply["truncated"]?.bool ?? false
    }
}

struct DiffPreviewTarget: Hashable, Identifiable {
    var path: String
    var id: String { path }
}

enum DiffPaths {
    static func join(_ root: String, _ relative: String) -> String {
        if relative.hasPrefix("/") { return relative }
        return root.hasSuffix("/") ? root + relative : root + "/" + relative
    }
}

extension ServiceClient {
    /// `git.diff` with an optional path filter and scope.
    func gitDiffText(cwd: String, path: String?, scope: DiffScope) async throws -> DiffPayload {
        var params: [String: JSONValue] = ["cwd": .string(cwd)]
        switch scope {
        case .workingTree: params["staged"] = .bool(false)
        case .staged: params["staged"] = .bool(true)
        case .base(let ref): params["base"] = .string(ref)
        }
        if let path { params["path"] = .string(path) }
        return DiffPayload(reply: try await call("git.diff", params))
    }

    /// `git.show`: a repository file's bytes at `rev`, or in the index.
    func gitShow(cwd: String, path: String, rev: String?) async throws -> Data {
        var params: [String: JSONValue] = ["cwd": .string(cwd), "path": .string(path)]
        if let rev { params["rev"] = .string(rev) }
        let reply = try await call("git.show", params)
        return Data(base64Encoded: reply["data"]?.string ?? "") ?? Data()
    }

    /// The repository root for `cwd` (diff paths are root-relative); falls
    /// back to `cwd` when it isn't a repository.
    func repoRoot(cwd: String) async -> String {
        (try? await gitStatus(cwd: cwd))?["root"]?.string ?? cwd
    }
}
