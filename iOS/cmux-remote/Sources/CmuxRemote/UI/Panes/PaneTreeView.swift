import SwiftUI
import CmuxKit

/// Shows the pane tree + the horizontal surface tab strip for the focused
/// pane. The actual surface body lives in `SurfaceDetailView` in the detail
/// column of the split — this view is the "content" column.
struct PaneTreeView: View {
    let workspace: CmuxWorkspace

    @EnvironmentObject var connection: ConnectionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneList
            Divider()
            surfaceStrip
        }
    }

    private var paneList: some View {
        let panes = connection.snapshot.panes.values.filter { $0.workspaceID == workspace.id }
        return List {
            ForEach(Array(panes), id: \.id) { pane in
                PaneRow(pane: pane,
                        isFocused: pane.id == connection.snapshot.focusedPaneID)
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await focus(pane) } }
            }
        }
        .frame(maxHeight: 180)
    }

    @ViewBuilder
    private var surfaceStrip: some View {
        if let paneID = connection.snapshot.focusedPaneID {
            let surfaces = connection.snapshot.surfaces.values.filter { $0.paneID == paneID }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(surfaces), id: \.id) { surface in
                        SurfaceChip(surface: surface,
                                    isFocused: surface.id == connection.snapshot.focusedSurfaceID)
                            .onTapGesture { Task { await focus(surface) } }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private func focus(_ pane: CmuxPane) async {
        // No standalone focus-pane CLI exposes via cmux — selecting a surface
        // inside the pane will also focus the pane.
        if let selected = pane.selectedSurfaceID,
           let surface = connection.snapshot.surfaces[selected] {
            await focus(surface)
        }
    }

    private func focus(_ surface: CmuxSurface) async {
        guard let client = await connection.client(for: "focus-surface") else { return }
        try? await client.focusSurface(surface.id, workspaceID: workspace.id)
    }
}

private struct PaneRow: View {
    let pane: CmuxPane
    let isFocused: Bool

    var body: some View {
        HStack {
            Image(systemName: "rectangle.split.3x1")
                .foregroundStyle(isFocused ? Color.accentColor : .secondary)
            Text(L10n.format("pane.row.title", defaultValue: "pane %@", String(pane.id.raw.prefix(8))))
                .font(.callout.monospaced())
            Spacer()
            if let frame = pane.frame {
                Text("\(Int(frame.width))×\(Int(frame.height))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SurfaceChip: View {
    let surface: CmuxSurface
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(surface.title ?? defaultTitle)
                .lineLimit(1)
                .font(.caption.weight(.medium))
            if surface.unreadCount > 0 {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isFocused
                ? AnyShapeStyle(Color.accentColor.opacity(0.2))
                : AnyShapeStyle(.regularMaterial),
            in: Capsule()
        )
    }

    private var icon: String {
        switch surface.kind {
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .markdown: return "doc.text"
        case .filePreview: return "doc"
        case .other: return "questionmark.square"
        }
    }

    private var defaultTitle: String {
        switch surface.kind {
        case .terminal: return L10n.string("surface.kind.terminal", defaultValue: "Terminal")
        case .browser: return L10n.string("surface.kind.browser", defaultValue: "Browser")
        case .markdown: return L10n.string("surface.kind.markdown", defaultValue: "Markdown")
        case .filePreview: return L10n.string("surface.kind.file", defaultValue: "File")
        case .other: return L10n.string("surface.default_title", defaultValue: "Surface")
        }
    }
}
