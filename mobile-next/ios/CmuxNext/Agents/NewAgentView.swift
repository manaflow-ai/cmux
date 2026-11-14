import CNMProtocol
import SwiftUI

/// The new-chat screen: a quiet greeting, the Mac / project / agent the chat
/// will run on as chips over the composer, and a few starters.
struct NewAgentView: View {
    @Environment(AppModel.self) private var model
    @Environment(ShellState.self) private var shell
    @State private var hostID: String?
    @State private var project: ProjectInfo?
    @State private var harness = "claude"
    @State private var draft = ""
    @State private var attachments: [ComposerImage] = []
    @State private var starting = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var host: HostConnection? {
        model.connectedHosts.first { $0.id == hostID } ?? model.connectedHosts.first
    }

    private let starters = [
        "Explain how this project is put together",
        "Find and fix a failing test",
        "Review my uncommitted changes",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()
                if let host {
                    VStack(spacing: 14) {
                        Text("What should we build?")
                            .font(.system(size: 26, weight: .semibold))
                        Text("Runs on \(host.name) in \(project?.name ?? "your home folder")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 24)
                } else {
                    ContentUnavailableView(
                        "No Mac connected", systemImage: "laptopcomputer.slash",
                        description: Text(model.hosts.isEmpty ? "Pair a Mac to start agents on it." : "Your Mac is offline. Start cnm-host on it.")
                    )
                }
                Spacer()
                if host != nil, draft.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(starters, id: \.self) { starter in
                                Button { draft = starter } label: {
                                    Text(starter)
                                        .font(.system(size: 15))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 12)
                                        .frame(width: 170, alignment: .leading)
                                        .multilineTextAlignment(.leading)
                                        .background(Color(.secondarySystemFill), in: .rect(cornerRadius: 16, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 10)
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(CmuxTheme.danger).padding(.bottom, 6).padding(.horizontal, 16)
                }
                if let host {
                    pickers(host)
                    AgentComposer(
                        text: $draft, attachments: $attachments, focused: $focused, placeholder: "Ask \(HarnessStyle.of(harness).name)",
                        working: starting, canSend: !starting, modes: [], currentMode: nil, models: [], currentModel: nil,
                        commands: [], onMode: { _ in }, onModel: { _ in }, send: { start(host) }, stop: {}
                    )
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { DrawerButton() }
                ToolbarItem(placement: .principal) { Text("New chat").font(.headline) }
            }
            .task(id: host?.id) {
                guard let host else { return }
                if host.projects.isEmpty { await host.loadProjects() }
                if project == nil { project = host.projects.first }
                if !host.harnesses.contains(where: { $0.id == harness && $0.available }),
                   let first = host.harnesses.first(where: \.available)
                {
                    harness = first.id
                }
            }
        }
    }

    private func pickers(_ host: HostConnection) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if model.connectedHosts.count > 1 {
                    Menu {
                        ForEach(model.connectedHosts) { item in
                            Button(item.name) {
                                hostID = item.id
                                project = nil
                            }
                        }
                    } label: {
                        chip(host.name, symbol: "laptopcomputer")
                    }
                }
                Menu {
                    Button("Home folder") { project = nil }
                    ForEach(host.projects) { item in
                        Button {
                            project = item
                        } label: {
                            Text(item.name)
                            if let branch = item.branch { Text(branch) }
                        }
                    }
                } label: {
                    chip(project?.name ?? String(localized: "Home folder"), symbol: "folder")
                }
                .accessibilityIdentifier("new.project")
                Menu {
                    ForEach(host.harnesses) { item in
                        Button {
                            harness = item.id
                        } label: {
                            Label(item.name, systemImage: HarnessStyle.of(item.id).symbol)
                            if !item.available { Text("Not installed") }
                        }
                        .disabled(!item.available)
                    }
                } label: {
                    chip(HarnessStyle.of(harness).name, symbol: HarnessStyle.of(harness).symbol)
                }
                .accessibilityIdentifier("new.harness")
            }
            .padding(.horizontal, 16)
        }
        .tint(.primary)
        .padding(.bottom, 8)
    }

    private func chip(_ title: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
            Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Color(.secondarySystemFill), in: .capsule)
    }

    private func start(_ host: HostConnection) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty, !starting else { return }
        let blocks = AgentChatView.blocks(text: text, images: attachments)
        starting = true
        error = nil
        let cwd = project?.path ?? host.hello?.homeDirectory ?? "~"
        Task {
            defer { starting = false }
            do {
                let info = try await host.createAgent(harness: harness, cwd: cwd, prompt: blocks)
                draft = ""
                attachments = []
                shell.go(.agent(host: host.id, session: info.id))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
