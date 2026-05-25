import SwiftUI
import CmuxKit

struct SnippetPickerView: View {
    let surface: CmuxSurface
    let workspace: CmuxWorkspace?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var connection: ConnectionManager
    @State private var snippets: [CmuxSnippet] = []

    private let store = CmuxSnippetStore.shared

    var body: some View {
        NavigationStack {
            List {
                if snippets.isEmpty {
                    ContentUnavailableView(
                        L10n.string("snippets.empty.title", defaultValue: "No snippets yet"),
                        systemImage: "text.append"
                    )
                }
                ForEach(snippets) { snippet in
                    Button {
                        Task { await send(snippet) }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(snippet.title).font(.headline)
                            Text(snippet.body)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task {
                                await store.remove(id: snippet.id)
                                await refresh()
                            }
                        } label: { Label(L10n.string("common.delete", defaultValue: "Delete"), systemImage: "trash") }
                    }
                }
            }
            .navigationTitle(L10n.string("snippets.title", defaultValue: "Snippets"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.string("common.cancel", defaultValue: "Cancel")) { dismiss() }
                }
            }
            .task { await refresh() }
        }
    }

    private func refresh() async {
        snippets = await store.all()
    }

    private func send(_ snippet: CmuxSnippet) async {
        await store.markUsed(id: snippet.id)
        guard let client = await connection.client(for: "send") else { return }
        try? await client.sendText(snippet.renderedPayload,
                                    surfaceID: surface.id,
                                    workspaceID: workspace?.id)
        dismiss()
    }
}

extension CmuxSnippetStore {
    static let shared: CmuxSnippetStore = {
        let url: URL
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.cmuxterm.remote") {
            url = group
        } else {
            url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        }
        return CmuxSnippetStore(appGroupURL: url)
    }()
}
