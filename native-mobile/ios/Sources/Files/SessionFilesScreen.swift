import SwiftUI

/// The session's files sheet: Referenced (paths and links mentioned in the
/// terminal), Browse (the working directory), and Changed (git status).
/// Place inside a NavigationStack (it registers its own destinations);
/// present it as a sheet.
struct SessionFilesScreen: View {
    enum Tab: String, CaseIterable, Identifiable {
        case referenced, browse, changed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .referenced: String(localized: "Referenced")
            case .browse: String(localized: "Browse")
            case .changed: String(localized: "Changed")
            }
        }
    }

    let cwd: String?
    let scrollbackText: @Sendable () async -> String
    let services: ServiceClient

    @State private var tab: Tab = .referenced
    @State private var query = ""
    @State private var safariURL: PresentedURL?
    @Environment(\.dismiss) private var dismiss

    init(cwd: String?, scrollbackText: @escaping @Sendable () async -> String, services: ServiceClient) {
        self.cwd = cwd
        self.scrollbackText = scrollbackText
        self.services = services
    }

    var body: some View {
        tabContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .safeAreaBar(edge: .top) {
                FilesChipTabs(selection: $tab)
            }
            .navigationTitle(String(localized: "Files"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: Text(searchPrompt))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "Close"), systemImage: "xmark") { dismiss() }
                }
            }
            .navigationDestination(for: FilesDestination.self) { destination in
                destinationView(destination)
            }
            // Browse starts in the working directory; the title menu climbs
            // to its parents, like a pushed folder's (Files app pattern).
            .modifier(BrowseParentsMenu(path: tab == .browse ? cwd : nil))
            .sheet(item: $safariURL) { item in
                SafariView(url: item.url).ignoresSafeArea()
            }
    }

    private var searchPrompt: String {
        switch tab {
        case .referenced: String(localized: "Search references")
        case .browse: String(localized: "Search this folder")
        case .changed: String(localized: "Search changes")
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .referenced:
            ReferencedFilesView(cwd: cwd, scrollbackText: scrollbackText, services: services, query: query) { url in
                safariURL = PresentedURL(url: url)
            }
        case .browse:
            if let cwd {
                DirectoryBrowserView(path: cwd, services: services, query: query)
            } else {
                noDirectory
            }
        case .changed:
            if let cwd {
                ChangedFilesView(cwd: cwd, services: services, query: query)
            } else {
                noDirectory
            }
        }
    }

    private var noDirectory: some View {
        StateMessageView(systemImage: "folder.badge.questionmark", title: String(localized: "No working directory"),
                       message: String(localized: "This terminal hasn't reported its current folder yet."))
    }

    @ViewBuilder private func destinationView(_ destination: FilesDestination) -> some View {
        switch destination {
        case .directory(let path):
            PushedDirectoryScreen(path: path, services: services)
        case .file(let path):
            FilePreviewScreen(path: path, services: services)
        case .diff(let root, let path, let staged):
            DiffScreen(cwd: root, services: services, path: path, scope: staged ? .staged : .workingTree)
        }
    }

}

/// ChatGPT Library-style chip tabs. They don't page with swipes (REFERENCES.md).
struct FilesChipTabs: View {
    @Binding var selection: SessionFilesScreen.Tab

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SessionFilesScreen.Tab.allCases) { tab in
                let selected = tab == selection
                Button {
                    Haptics.selection()
                    selection = tab
                } label: {
                    Text(tab.title)
                        .font(.subheadline.weight(.semibold))
                        // ChatGPT Library chips: the selected one is a tinted
                        // capsule, the others plain secondary text.
                        .foregroundStyle(selected ? Theme.ink : Theme.secondaryInk)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background {
                            if selected { Capsule().fill(Color.primary.opacity(0.12)) }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

/// A pushed folder with its own search and an ancestor title menu.
private struct PushedDirectoryScreen: View {
    let path: String
    let services: ServiceClient
    @State private var query = ""

    var body: some View {
        DirectoryBrowserView(path: path, services: services, query: query)
            .navigationTitle(path == "/" ? "/" : (path as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: Text(String(localized: "Search this folder")))
            .toolbarTitleMenu {
                DirectoryBreadcrumbs(path: path)
            }
    }
}

private struct BrowseParentsMenu: ViewModifier {
    let path: String?

    func body(content: Content) -> some View {
        if let path, !DirectoryBreadcrumbs.ancestors(of: path).isEmpty {
            content.toolbarTitleMenu { DirectoryBreadcrumbs(path: path) }
        } else {
            content
        }
    }
}

/// Files, folders and links mentioned in the terminal scrollback.
private struct ReferencedFilesView: View {
    let cwd: String?
    let scrollbackText: @Sendable () async -> String
    let services: ServiceClient
    let query: String
    let openURL: (URL) -> Void

    @State private var refs: [HostFileRef]?
    @State private var failure: String?

    var body: some View {
        Group {
            if let failure {
                LoadFailedView(title: String(localized: "Couldn't load references"), message: failure) {
                    Task { await load() }
                }
            } else if let refs {
                let groups = SessionRefGroup.make(refs, query: query)
                if groups.isEmpty {
                    StateMessageView(
                        systemImage: query.isEmpty ? "doc.text.magnifyingglass" : "magnifyingglass",
                        title: query.isEmpty ? String(localized: "No references yet") : String(localized: "No results"),
                        message: query.isEmpty
                            ? String(localized: "Files, folders and links mentioned in this session appear here.")
                            : String(localized: "Nothing matches \u{201C}\(query)\u{201D}.")
                    )
                } else {
                    List {
                        ForEach(groups) { group in
                            Section(group.kind.title) {
                                ForEach(group.refs) { ref in
                                    row(ref, kind: group.kind)
                                        .listRowBackground(Color.clear)
                                        .contextMenu {
                                            Button(String(localized: "Copy"), systemImage: "doc.on.doc") {
                                                UIPasteboard.general.string = ref.path
                                            }
                                        }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable { await load() }
                }
            } else {
                LoadingSkeleton(label: String(localized: "Finding references"))
            }
        }
        .task { if refs == nil { await load() } }
    }

    @ViewBuilder private func row(_ ref: HostFileRef, kind: SessionRefGroup.Kind) -> some View {
        switch kind {
        case .links:
            Button {
                if let url = URL(string: ref.path), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                    openURL(url)
                }
            } label: {
                ReferenceRow(ref: ref, cwd: cwd)
            }
            .buttonStyle(.plain)
        case .folders:
            NavigationLink(value: FilesDestination.directory(ref.path)) { ReferenceRow(ref: ref, cwd: cwd) }
        case .files:
            NavigationLink(value: FilesDestination.file(ref.path)) { ReferenceRow(ref: ref, cwd: cwd) }
        }
    }

    private func load() async {
        let text = await scrollbackText()
        do {
            refs = try await services.refs(cwd: cwd, text: text)
            failure = nil
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct ReferenceRow: View {
    let ref: HostFileRef
    let cwd: String?

    var body: some View {
        let kind = SessionRefGroup.kind(of: ref)
        HStack(spacing: 12) {
            Image(systemName: FileSymbol.symbol(path: ref.path, isDirectory: kind == .folders, isURL: kind == .links))
                .foregroundStyle(kind == .folders ? Theme.ink : Theme.secondaryInk)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind == .links ? (URL(string: ref.path)?.host() ?? ref.path) : (ref.path as NSString).lastPathComponent)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(kind == .links ? ref.path : FileFormat.display(ref.path, relativeTo: cwd))
                        .lineLimit(1)
                        .truncationMode(.head)
                    if let size = FileFormat.size(ref.size), kind == .files {
                        Text(verbatim: "\u{00B7} \(size)")
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.secondaryInk)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }
}

/// `git status` entries with M/A/D badges; tapping opens the file's diff.
private struct ChangedFilesView: View {
    let cwd: String
    let services: ServiceClient
    let query: String

    @State private var root: String?
    @State private var files: [GitChangedFile]?
    @State private var failure: String?

    private var visible: [GitChangedFile] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return files ?? [] }
        return (files ?? []).filter { $0.path.lowercased().contains(needle) }
    }

    var body: some View {
        Group {
            if let failure {
                LoadFailedView(title: String(localized: "Couldn't load changes"), message: failure) {
                    Task { await load() }
                }
            } else if files == nil {
                LoadingSkeleton(label: String(localized: "Loading changes"))
            } else if visible.isEmpty {
                StateMessageView(
                    systemImage: query.isEmpty ? "checkmark.circle" : "magnifyingglass",
                    title: query.isEmpty ? String(localized: "No changes") : String(localized: "No results"),
                    message: query.isEmpty ? String(localized: "The working tree is clean.") : String(localized: "No changed files match \u{201C}\(query)\u{201D}.")
                )
            } else {
                List(visible) { file in
                    NavigationLink(value: FilesDestination.diff(root: root ?? cwd, path: file.path, staged: file.staged && !file.unstaged)) {
                        ChangedFileRow(file: file)
                    }
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            }
        }
        .task { if files == nil { await load() } }
    }

    private func load() async {
        do {
            let parsed = GitChangedFile.parse(try await services.gitStatus(cwd: cwd))
            root = parsed.root
            files = parsed.files
            failure = nil
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct ChangedFileRow: View {
    let file: GitChangedFile

    private var color: Color {
        switch file.badge {
        case "A", "U": DiffColors.addText
        case "D": DiffColors.delText
        case "!": Theme.danger
        default: Theme.attention
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: file.badge)
                .font(Theme.mono(12, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(color.opacity(0.15), in: .rect(cornerRadius: 5))
                .accessibilityLabel(file.status)
            VStack(alignment: .leading, spacing: 2) {
                Text((file.path as NSString).lastPathComponent)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                let directory = (file.path as NSString).deletingLastPathComponent
                if !directory.isEmpty || file.oldPath != nil {
                    Text(file.oldPath.map { String(localized: "from \($0)") } ?? directory)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
            if file.staged {
                Text(String(localized: "Staged"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.elevated, in: .capsule)
            }
        }
        .padding(.vertical, 2)
    }
}
