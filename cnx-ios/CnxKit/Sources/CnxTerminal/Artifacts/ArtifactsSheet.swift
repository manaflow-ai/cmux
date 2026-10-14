#if os(iOS)
import SwiftUI

/// Everything the session referenced (SPEC 11.2-11.4): files, folders and
/// links parsed from the output, filtered by chips, each opening a preview.
struct ArtifactsSheet: View {
    @Bindable var model: TerminalModel
    @State private var filter: Filter = .all
    @Environment(\.dismiss) private var dismiss

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", files = "Files", folders = "Folders", images = "Images", videos = "Videos", code = "Code", links = "Links"
        var id: String { rawValue }

        func includes(_ kind: TerminalArtifact.Kind) -> Bool {
            switch self {
            case .all: true
            case .files: ![.directory, .link].contains(kind)
            case .folders: kind == .directory
            case .images: kind == .image
            case .videos: kind == .video
            case .code: [.code, .html, .markdown, .text].contains(kind)
            case .links: kind == .link
            }
        }
    }

    private var shown: [TerminalArtifact] {
        model.artifacts.filter { filter.includes($0.kind) }.sorted { $0.order > $1.order }
    }

    var body: some View {
        NavigationStack(path: $model.artifactPath) {
            List {
                Section {
                    ForEach(shown) { artifact in
                        NavigationLink(value: artifact) { ArtifactRow(artifact: artifact) }
                    }
                } header: {
                    chips
                }
            }
            .listStyle(.plain)
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView("Nothing referenced yet", systemImage: "doc.text.magnifyingglass",
                                           description: Text("Files, folders and links that appear in the terminal show up here."))
                }
            }
            .navigationTitle("Files and links")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: TerminalArtifact.self) { artifact in
                ArtifactPreview(artifact: artifact, source: model.artifactSource, showSource: $model.previewShowsSource)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "checkmark", role: .confirm) { dismiss() }
                }
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { item in
                    let count = model.artifacts.filter { item.includes($0.kind) }.count
                    Button {
                        withAnimation(.snappy) { filter = item }
                    } label: {
                        Text(item == .all ? "All \(count)" : item.rawValue)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Color.primary.opacity(filter == item ? 0.16 : 0.06), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .disabled(count == 0)
                    .opacity(count == 0 ? 0.4 : 1)
                }
            }
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .textCase(nil)
        .foregroundStyle(.primary)
    }
}
#endif
