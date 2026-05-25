import SwiftUI
import CmuxKit

struct WorkspaceSidebarView: View {
    let host: CmuxHost

    @EnvironmentObject var connection: ConnectionManager

    var body: some View {
        List {
            ForEach(sortedWindows, id: \.id) { window in
                Section(window.title ?? L10n.string("window.default_title", defaultValue: "Window")) {
                    let workspaces = connection.snapshot.workspaces.values
                        .filter { $0.windowID == window.id }
                        .sorted(by: { $0.index < $1.index })
                    ForEach(workspaces, id: \.id) { workspace in
                        WorkspaceRow(workspace: workspace,
                                     isSelected: workspace.id == connection.snapshot.focusedWorkspaceID)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Task { await select(workspace) }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task { await close(workspace) }
                                } label: {
                                    Label(L10n.string("common.close", defaultValue: "Close"), systemImage: "xmark")
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .refreshable {
            await connection.handleEnterForeground()
        }
    }

    private var sortedWindows: [CmuxWindow] {
        connection.snapshot.windows.values.sorted { lhs, rhs in
            if lhs.isKey != rhs.isKey { return lhs.isKey && !rhs.isKey }
            let lhsTitle = lhs.title ?? ""
            let rhsTitle = rhs.title ?? ""
            if lhsTitle != rhsTitle { return lhsTitle < rhsTitle }
            return lhs.id.raw < rhs.id.raw
        }
    }

    private func select(_ workspace: CmuxWorkspace) async {
        guard let client = await connection.client(for: "select-workspace") else { return }
        try? await client.selectWorkspace(workspace.id)
    }

    private func close(_ workspace: CmuxWorkspace) async {
        guard let client = await connection.client(for: "close-workspace") else { return }
        try? await client.closeWorkspace(workspace.id)
    }
}

struct WorkspaceRow: View {
    let workspace: CmuxWorkspace
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if workspace.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text(workspace.title ?? L10n.string("workspace.untitled", defaultValue: "(untitled)"))
                        .font(.headline)
                    if workspace.isRemote {
                        Image(systemName: "network")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let branch = workspace.branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !workspace.listeningPorts.isEmpty {
                    Text(workspace.listeningPorts.map(String.init).joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if workspace.unreadCount > 0 {
                Text("\(workspace.unreadCount)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.blue, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(.vertical, 2)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }
}
