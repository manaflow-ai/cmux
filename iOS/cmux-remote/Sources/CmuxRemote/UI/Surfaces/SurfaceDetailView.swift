import SwiftUI
import CmuxKit

struct SurfaceDetailView: View {
    let surface: CmuxSurface
    @EnvironmentObject var connection: ConnectionManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var showCommandPalette = false
    @State private var showPencilOverlay = false
    @State private var showSnippets = false

    private var workspace: CmuxWorkspace? {
        connection.snapshot.workspaces[surface.workspaceID]
    }

    var body: some View {
        ZStack {
            switch surface.kind {
            case .terminal:
                TerminalSurfaceView(
                    surface: surface,
                    workspace: workspace,
                    isActive: scenePhase == .active && connection.snapshot.focusedSurfaceID == surface.id
                )
                    .background(Color.black)
                    .ignoresSafeArea(.keyboard)
            case .browser:
                BrowserSurfaceView(surface: surface, workspace: workspace)
            case .markdown, .filePreview, .other:
                MarkdownSurfaceView(surface: surface, workspace: workspace)
            }
            if showPencilOverlay {
                PencilOverlayView(isPresented: $showPencilOverlay) { recognized in
                    Task {
                        guard let client = await connection.client(for: "send") else { return }
                        try? await client.sendText(recognized, surfaceID: surface.id, workspaceID: workspace?.id)
                    }
                }
            }
        }
        .navigationTitle(surface.title ?? defaultTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if surface.kind == .terminal {
                    Button {
                        showPencilOverlay = true
                    } label: {
                        Label(L10n.string("surface.action.pencil", defaultValue: "Pencil"), systemImage: "pencil.tip")
                    }
                }
                Button {
                    showSnippets = true
                } label: {
                    Label(L10n.string("surface.action.snippets", defaultValue: "Snippets"), systemImage: "text.append")
                }
                Button {
                    showCommandPalette = true
                } label: {
                    Label(L10n.string("surface.action.palette", defaultValue: "Palette"), systemImage: "command")
                }
                .keyboardShortcut("p", modifiers: [.command])
            }
        }
        .sheet(isPresented: $showCommandPalette) {
            CommandPaletteView(surface: surface, workspace: workspace)
        }
        .sheet(isPresented: $showSnippets) {
            SnippetPickerView(surface: surface, workspace: workspace)
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
