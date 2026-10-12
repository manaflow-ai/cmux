import SwiftUI

/// Where the files sheet navigates.
enum FilesDestination: Hashable {
    case directory(String)
    case file(String)
    /// The diff of one path: repository root, root-relative path, staged-only.
    case diff(root: String, path: String, staged: Bool)
}

/// One directory: folders first, then files, with size and modified date.
/// Embedded as the Browse tab root and pushed for subfolders.
struct DirectoryBrowserView: View {
    let path: String
    let services: ServiceClient
    let query: String

    @State private var entries: [HostFileEntry]?
    @State private var failure: String?

    private var visible: [HostFileEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = (entries ?? []).sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        guard !needle.isEmpty else { return sorted }
        return sorted.filter { $0.name.lowercased().contains(needle) }
    }

    var body: some View {
        Group {
            if let failure {
                DiffFailureState(title: String(localized: "Couldn't load folder"), message: failure) {
                    Task { await load() }
                }
            } else if entries == nil {
                DiffLoadingState(label: String(localized: "Loading folder"))
            } else if visible.isEmpty {
                DiffEmptyState(
                    symbol: query.isEmpty ? "folder" : "magnifyingglass",
                    title: query.isEmpty ? String(localized: "Empty folder") : String(localized: "No results"),
                    message: query.isEmpty ? String(localized: "This folder has no files.") : String(localized: "No files match \u{201C}\(query)\u{201D}.")
                )
            } else {
                List(visible) { entry in
                    NavigationLink(value: entry.isDirectory ? FilesDestination.directory(entry.path) : FilesDestination.file(entry.path)) {
                        FileEntryRow(entry: entry)
                    }
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        Button(String(localized: "Copy Path"), systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = entry.path
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            }
        }
        .background(Theme.background)
        .task(id: path) { await load() }
    }

    private func load() async {
        do {
            entries = try await services.list(path: path)
            failure = nil
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
    }
}

struct FileEntryRow: View {
    let entry: HostFileEntry

    private var detail: String {
        var parts: [String] = []
        if !entry.isDirectory, let size = FileFormat.size(entry.size) { parts.append(size) }
        if let modified = FileFormat.modified(entry.modified) { parts.append(modified) }
        return parts.joined(separator: " \u{00B7} ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : FileSymbol.symbol(path: entry.path))
                .font(.body)
                .foregroundStyle(entry.isDirectory ? Theme.ink : Theme.secondaryInk)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.body)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Breadcrumb title menu for a pushed directory: each ancestor opens there.
struct DirectoryBreadcrumbs: View {
    let path: String

    static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var current = path
        while current != "/" && !current.isEmpty {
            current = (current as NSString).deletingLastPathComponent
            if current.isEmpty { break }
            result.append(current)
        }
        return result
    }

    var body: some View {
        ForEach(Self.ancestors(of: path), id: \.self) { ancestor in
            NavigationLink(value: FilesDestination.directory(ancestor)) {
                Label(ancestor == "/" ? "/" : (ancestor as NSString).lastPathComponent, systemImage: "folder")
            }
        }
    }
}
