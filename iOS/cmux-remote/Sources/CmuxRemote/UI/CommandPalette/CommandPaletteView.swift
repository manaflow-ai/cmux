import SwiftUI
import CmuxKit

/// Command palette mirroring cmux's macOS palette — fuzzy-match across
/// workspaces, surfaces, common actions. Surfaces selected through the
/// palette focus the corresponding entity on the Mac via the same socket
/// commands `cmux <command>` exposes from the CLI.
struct CommandPaletteView: View {
    let surface: CmuxSurface?
    let workspace: CmuxWorkspace?

    @EnvironmentObject var connection: ConnectionManager
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                Divider()
                List {
                    if filteredActions.isEmpty && filteredWorkspaces.isEmpty && filteredSurfaces.isEmpty {
                        ContentUnavailableView(
                            L10n.string("command_palette.empty.title", defaultValue: "No matches"),
                            systemImage: "magnifyingglass"
                        )
                    }
                    if !filteredActions.isEmpty {
                        Section(L10n.string("command_palette.section.actions", defaultValue: "Actions")) {
                            ForEach(filteredActions, id: \.id) { row in
                                Button {
                                    Task { await row.perform(connection); dismiss() }
                                } label: {
                                    Label(row.title, systemImage: row.icon)
                                }
                            }
                        }
                    }
                    if !filteredWorkspaces.isEmpty {
                        Section(L10n.string("command_palette.section.workspaces", defaultValue: "Workspaces")) {
                            ForEach(filteredWorkspaces, id: \.id) { workspace in
                                Button {
                                    Task {
                                        guard let client = await connection.client(for: "select-workspace") else { return }
                                        try? await client.selectWorkspace(workspace.id)
                                        dismiss()
                                    }
                                } label: {
                                    Label(
                                        workspace.title ?? L10n.string("workspace.untitled", defaultValue: "(untitled)"),
                                        systemImage: "rectangle.split.3x1"
                                    )
                                }
                            }
                        }
                    }
                    if !filteredSurfaces.isEmpty {
                        Section(L10n.string("command_palette.section.surfaces", defaultValue: "Surfaces")) {
                            ForEach(filteredSurfaces, id: \.id) { surface in
                                Button {
                                    Task {
                                        guard let client = await connection.client(for: "focus-surface") else { return }
                                        try? await client.focusSurface(surface.id, workspaceID: surface.workspaceID)
                                        dismiss()
                                    }
                                } label: {
                                    Label(
                                        surface.title ?? L10n.string("surface.default_title", defaultValue: "Surface"),
                                        systemImage: surface.kind == .terminal ? "terminal" : "globe"
                                    )
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle(L10n.string("command_palette.title", defaultValue: "Command Palette"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.string("common.cancel", defaultValue: "Cancel")) { dismiss() }
                }
            }
        }
        .onAppear { fieldFocused = true }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L10n.string("command_palette.search.placeholder", defaultValue: "Type a command"), text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($fieldFocused)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Filtering

    private var filteredWorkspaces: [CmuxWorkspace] {
        let q = query.lowercased()
        guard !q.isEmpty else { return Array(connection.snapshot.workspaces.values.prefix(8)) }
        return connection.snapshot.workspaces.values.filter {
            ($0.title?.lowercased().contains(q) ?? false)
                || ($0.branch?.lowercased().contains(q) ?? false)
                || ($0.cwd?.lowercased().contains(q) ?? false)
        }
    }

    private var filteredSurfaces: [CmuxSurface] {
        let q = query.lowercased()
        guard !q.isEmpty else { return Array(connection.snapshot.surfaces.values.prefix(8)) }
        return connection.snapshot.surfaces.values.filter {
            $0.title?.lowercased().contains(q) ?? false
        }
    }

    private var filteredActions: [CommandPaletteAction] {
        let q = query.lowercased()
        return CommandPaletteAction.allActions.filter {
            q.isEmpty || $0.title.lowercased().contains(q)
        }
    }
}

struct CommandPaletteAction: Identifiable {
    let id: String
    let title: String
    let icon: String
    let perform: @MainActor (_ connection: ConnectionManager) async -> Void

    @MainActor
    static let allActions: [CommandPaletteAction] = [
        CommandPaletteAction(id: "jump", title: L10n.string("command_palette.action.jump_to_unread", defaultValue: "Jump to unread"), icon: "bell") { c in
            guard let client = await c.client(for: "jump-to-unread") else { return }
            try? await client.jumpToUnread()
        },
        CommandPaletteAction(id: "new-workspace", title: L10n.string("command_palette.action.new_workspace", defaultValue: "New workspace"), icon: "plus.rectangle") { c in
            guard let client = await c.client(for: "new-workspace") else { return }
            _ = try? await client.newWorkspace()
        },
        CommandPaletteAction(id: "reload", title: L10n.string("command_palette.action.reload_snapshot", defaultValue: "Reload snapshot"), icon: "arrow.clockwise") { c in
            await c.handleEnterForeground()
        },
        CommandPaletteAction(id: "disconnect", title: L10n.string("command_palette.action.disconnect", defaultValue: "Disconnect"), icon: "power") { c in
            await c.disconnect()
        }
    ]
}
