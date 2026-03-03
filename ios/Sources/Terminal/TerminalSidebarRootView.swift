import SwiftUI

struct TerminalSidebarRootView: View {
    @StateObject private var store = TerminalSidebarStore()

    var body: some View {
        NavigationSplitView {
            List(store.workspaces, selection: $store.selectedWorkspaceID) { workspace in
                TerminalWorkspaceRow(workspace: workspace)
                    .tag(workspace.id)
            }
            .listStyle(.sidebar)
            .navigationTitle("cmux")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        store.addWorkspace()
                    } label: {
                        Label("New Terminal", systemImage: "square.and.pencil")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: ConversationListView()) {
                        Label("Legacy Tasks", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    }
                }
            }
        } detail: {
            if let workspace = store.selectedWorkspace {
                TerminalWorkspaceDetail(
                    workspace: workspace,
                    controller: store.controller(for: workspace)
                )
            } else {
                ContentUnavailableView(
                    "No Terminal Selected",
                    systemImage: "terminal",
                    description: Text("Create or select a terminal workspace to continue.")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

@MainActor
final class TerminalSidebarStore: ObservableObject {
    @Published private(set) var workspaces: [TerminalWorkspace]
    @Published var selectedWorkspaceID: TerminalWorkspace.ID?

    private var controllers: [TerminalWorkspace.ID: GhosttyToyTerminalController] = [:]

    init() {
        let initial = TerminalWorkspace.seed
        self.workspaces = initial
        self.selectedWorkspaceID = initial.first?.id
    }

    var selectedWorkspace: TerminalWorkspace? {
        guard let selectedWorkspaceID else { return nil }
        return workspaces.first(where: { $0.id == selectedWorkspaceID })
    }

    func addWorkspace() {
        let count = workspaces.count + 1
        let workspace = TerminalWorkspace(
            title: "Terminal \(count)",
            subtitle: "Toy libghostty session",
            systemImage: "terminal",
            trailingStatus: "now",
            launchConfig: GhosttyToySurfaceView.LaunchConfig(
                workingDirectory: NSHomeDirectory(),
                command: "/bin/sh",
                initialInput: "echo 'cmux iOS toy terminal ready';\n"
            )
        )
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
    }

    func controller(for workspace: TerminalWorkspace) -> GhosttyToyTerminalController {
        if let existing = controllers[workspace.id] {
            return existing
        }
        let controller = GhosttyToyTerminalController(workspace: workspace)
        controllers[workspace.id] = controller
        return controller
    }
}

struct TerminalWorkspace: Identifiable {
    typealias ID = UUID

    let id: ID
    let title: String
    let subtitle: String
    let systemImage: String
    let trailingStatus: String
    let launchConfig: GhosttyToySurfaceView.LaunchConfig

    init(
        id: ID = UUID(),
        title: String,
        subtitle: String,
        systemImage: String,
        trailingStatus: String,
        launchConfig: GhosttyToySurfaceView.LaunchConfig
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.trailingStatus = trailingStatus
        self.launchConfig = launchConfig
    }

    static let seed: [TerminalWorkspace] = [
        TerminalWorkspace(
            title: "Build",
            subtitle: "Workspace terminal",
            systemImage: "hammer.fill",
            trailingStatus: "now",
            launchConfig: GhosttyToySurfaceView.LaunchConfig(
                workingDirectory: NSHomeDirectory(),
                command: "/bin/sh",
                initialInput: "echo 'Build terminal (toy)';\n"
            )
        ),
        TerminalWorkspace(
            title: "Debug",
            subtitle: "Logs and checks",
            systemImage: "ladybug.fill",
            trailingStatus: "2m",
            launchConfig: GhosttyToySurfaceView.LaunchConfig(
                workingDirectory: NSHomeDirectory(),
                command: "/bin/sh",
                initialInput: "echo 'Debug terminal (toy)';\n"
            )
        ),
        TerminalWorkspace(
            title: "Review",
            subtitle: "PR notes",
            systemImage: "doc.text.magnifyingglass",
            trailingStatus: "5m",
            launchConfig: GhosttyToySurfaceView.LaunchConfig(
                workingDirectory: NSHomeDirectory(),
                command: "/bin/sh",
                initialInput: "echo 'Review terminal (toy)';\n"
            )
        ),
    ]
}

private struct TerminalWorkspaceRow: View {
    let workspace: TerminalWorkspace

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.85), Color.cyan.opacity(0.65)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: workspace.systemImage)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(workspace.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(workspace.trailingStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct TerminalWorkspaceDetail: View {
    let workspace: TerminalWorkspace
    @ObservedObject var controller: GhosttyToyTerminalController

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(workspace.title)
                        .font(.title3.weight(.semibold))
                    Text("Sidebar terminal prototype powered by libghostty")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Group {
                if let message = controller.errorMessage {
                    ContentUnavailableView(
                        "Terminal Failed",
                        systemImage: "exclamationmark.triangle.fill",
                        description: Text(message)
                    )
                } else if let surfaceView = controller.surfaceView {
                    GhosttyToyTerminalRepresentable(surfaceView: surfaceView)
                } else {
                    ProgressView("Starting terminal...")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.94))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .padding(16)
        .navigationTitle(workspace.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct GhosttyToyTerminalRepresentable: UIViewRepresentable {
    let surfaceView: GhosttyToySurfaceView

    func makeUIView(context: Context) -> GhosttyToySurfaceView {
        surfaceView
    }

    func updateUIView(_ uiView: GhosttyToySurfaceView, context: Context) {}
}

@MainActor
final class GhosttyToyTerminalController: ObservableObject {
    let workspaceID: TerminalWorkspace.ID
    @Published private(set) var errorMessage: String?
    private(set) var runtime: GhosttyToyRuntime?
    private(set) var surfaceView: GhosttyToySurfaceView?

    init(workspace: TerminalWorkspace) {
        self.workspaceID = workspace.id
        bootstrap(with: workspace.launchConfig)
    }

    private func bootstrap(with launchConfig: GhosttyToySurfaceView.LaunchConfig) {
        do {
            let runtime = try GhosttyToyRuntime()
            let view = GhosttyToySurfaceView(runtime: runtime, launchConfig: launchConfig)
            self.runtime = runtime
            self.surfaceView = view
            self.errorMessage = nil
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
}
