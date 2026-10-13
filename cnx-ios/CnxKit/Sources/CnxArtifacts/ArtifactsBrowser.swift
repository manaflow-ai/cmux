import Foundation

/// The browser's filter chips (SPEC 11.3), shared by the terminal and agent sessions.
public enum ArtifactFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All", files = "Files", folders = "Folders", images = "Images", videos = "Videos",
         documents = "Documents", code = "Code", links = "Links"
    public var id: String { rawValue }

    public func includes(_ kind: TerminalArtifact.Kind) -> Bool {
        switch self {
        case .all: true
        case .files: ![.directory, .link].contains(kind)
        case .folders: kind == .directory
        case .images: kind == .image
        case .videos: kind == .video
        case .documents: [.html, .markdown, .pdf, .text].contains(kind)
        case .code: kind == .code
        case .links: kind == .link
        }
    }
}

#if os(iOS)
import SwiftUI

/// Navigation and view state of one artifacts browser (the demo driver sets it too).
@MainActor
@Observable
public final class ArtifactsBrowserState {
    public var path: [TerminalArtifact] = []
    public var filter: ArtifactFilter = .all
    public var showSource = false
    public var grid = false

    public init() {}
}

/// Everything a session referenced, filtered by chips, as a list or a
/// ChatGPT Library style grid; each item opens its best preview. Owns its
/// navigation stack (present it in a sheet).
public struct ArtifactsBrowser: View {
    let title: String
    let artifacts: [TerminalArtifact]
    let source: any ArtifactSource
    let emptyMessage: String
    @Bindable var state: ArtifactsBrowserState
    @Environment(\.dismiss) private var dismiss

    public init(title: String, artifacts: [TerminalArtifact], source: any ArtifactSource, state: ArtifactsBrowserState,
                emptyMessage: String) {
        self.title = title
        self.artifacts = artifacts
        self.source = source
        self.state = state
        self.emptyMessage = emptyMessage
    }

    private var shown: [TerminalArtifact] {
        artifacts.filter { state.filter.includes($0.kind) }.sorted { $0.order > $1.order }
    }

    private var filters: [ArtifactFilter] {
        ArtifactFilter.allCases.filter { filter in filter == .all || artifacts.contains { filter.includes($0.kind) } }
    }

    public var body: some View {
        NavigationStack(path: $state.path) {
            Group {
                if state.grid {
                    ScrollView {
                        chips.padding(.horizontal, 20)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            ForEach(shown) { artifact in
                                NavigationLink(value: artifact) { ArtifactTile(artifact: artifact, source: source) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                } else {
                    List {
                        Section {
                            ForEach(shown) { artifact in
                                NavigationLink(value: artifact) { ArtifactRow(artifact: artifact) }
                                    .contextMenu {
                                        Button("Copy path", systemImage: "doc.on.doc") { UIPasteboard.general.string = artifact.reference }
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button("Copy path", systemImage: "doc.on.doc") { UIPasteboard.general.string = artifact.reference }
                                            .tint(.gray)
                                    }
                            }
                        } header: {
                            chips
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView("Nothing referenced yet", systemImage: "doc.text.magnifyingglass",
                                           description: Text(emptyMessage))
                }
            }
            .animation(.snappy, value: state.grid)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: TerminalArtifact.self) { artifact in
                ArtifactPreview(artifact: artifact, source: source, showSource: $state.showSource)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(state.grid ? "List" : "Grid", systemImage: state.grid ? "list.bullet" : "square.grid.2x2") {
                        state.grid.toggle()
                    }
                    .accessibilityIdentifier("artifacts.layout")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "checkmark", role: .confirm) { dismiss() }
                }
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(filters) { item in
                    let count = artifacts.filter { item.includes($0.kind) }.count
                    Button {
                        withAnimation(.snappy) { state.filter = item }
                    } label: {
                        Text(item == .all ? "All \(count)" : item.rawValue)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Color.primary.opacity(state.filter == item ? 0.16 : 0.06), in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(state.filter == item ? .isSelected : [])
                }
            }
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .textCase(nil)
        .foregroundStyle(.primary)
        .sensoryFeedback(.selection, trigger: state.filter)
    }
}

/// One referenced item: type glyph, name, then how it was referenced (or its path).
public struct ArtifactRow: View {
    let artifact: TerminalArtifact

    public init(artifact: TerminalArtifact) {
        self.artifact = artifact
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: artifact.systemImage)
                .font(.system(size: 18))
                .foregroundStyle(artifact.kind == .directory ? Color.secondary : Color.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.name).font(.body).lineLimit(1)
                HStack(spacing: 4) {
                    if let detail = artifact.detail {
                        Text(detail).foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(artifact.reference + (artifact.line.map { ":\($0)" } ?? ""))
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                }
                .font(.footnote)
                .lineLimit(1)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

/// A 1:1 grid tile (SPEC 11.3): image thumbnails, a glyph card otherwise.
struct ArtifactTile: View {
    let artifact: TerminalArtifact
    let source: any ArtifactSource
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                    } else {
                        Image(systemName: artifact.systemImage)
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                    }
                }
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(.rect(cornerRadius: 16, style: .continuous))
            Text(artifact.name).font(.footnote).lineLimit(2)
            if let detail = artifact.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .task(id: artifact) {
            guard artifact.kind == .image, thumbnail == nil,
                  case .image(let data)? = try? await source.load(artifact) else { return }
            thumbnail = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 360, height: 360))
        }
    }
}
#endif
