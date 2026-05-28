import SwiftUI
import CmuxKit

struct SnippetPickerView: View {
    let surface: CmuxSurface
    let workspace: CmuxWorkspace?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var connection: ConnectionManager
    @State private var snippets: [CmuxSnippet] = []
    @State private var sendError: String?

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
            .alert(
                L10n.string("snippets.error.title", defaultValue: "Snippet failed"),
                isPresented: Binding(
                    get: { sendError != nil },
                    set: { if !$0 { sendError = nil } }
                )
            ) {
                Button(L10n.string("common.ok", defaultValue: "OK"), role: .cancel) {}
            } message: {
                Text(sendError ?? "")
            }
        }
    }

    private func refresh() async {
        snippets = await store.all()
    }

    private func send(_ snippet: CmuxSnippet) async {
        guard let client = await connection.client(for: "send") else { return }
        do {
            try await client.sendText(
                snippet.renderedPayload,
                surfaceID: surface.id,
                workspaceID: workspace?.id
            )
            await store.markUsed(id: snippet.id)
            dismiss()
        } catch {
            sendError = L10n.string(
                "snippets.error.send_failed",
                defaultValue: "Could not send this snippet."
            )
        }
    }
}

extension CmuxSnippetStore {
    static let shared: CmuxSnippetStore = {
        let url: URL
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.cmuxterm.remote") {
            url = group
        } else {
            url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        }
        return CmuxSnippetStore(appGroupURL: url)
    }()
}
