#if os(iOS)
public import CNTransport
public import SwiftUI
import CNCore
import CNDesign

/// The Agents module root: the session list in a NavigationStack, the new
/// session sheet, and the chat screen pushed for a session. Shows the shell's
/// leading bar item (the drawer hamburger) on the list.
public struct AgentsRoot: View {
    let connection: HostConnection
    @State private var directory: AgentDirectory
    @State private var path: [String] = []
    @State private var creating = false

    public init(connection: HostConnection) {
        self.connection = connection
        _directory = State(initialValue: AgentDirectory(connection: connection))
        #if DEBUG
        _path = State(initialValue: AgentDebug.openSession.map { [$0] } ?? [])
        _creating = State(initialValue: AgentDebug.newSession)
        #endif
    }

    public var body: some View {
        NavigationStack(path: $path) {
            AgentSessionList(directory: directory, open: { path = [$0] }, create: { creating = true })
                .navigationTitle("Agents")
                .cnShellLeadingBarItem()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { creating = true } label: { Image(systemName: "square.and.pencil") }
                            .accessibilityLabel("New session")
                            .accessibilityIdentifier("agent.newSession")
                    }
                }
                .navigationDestination(for: String.self) { id in
                    AgentChatScreen(connection: connection, sessionId: id)
                }
        }
        .task { await directory.listen() }
        .task(id: connection.generation) { await directory.reload() }
        .sheet(isPresented: $creating) {
            NewSessionSheet(directory: directory) { session in
                creating = false
                path = [session.id]
            }
        }
    }
}

/// One session as the main content (the drawer shell's selected session).
public struct AgentChatView: View {
    let connection: HostConnection
    let sessionId: String

    public init(connection: HostConnection, sessionId: String) {
        self.connection = connection
        self.sessionId = sessionId
    }

    public var body: some View {
        NavigationStack {
            AgentChatScreen(connection: connection, sessionId: sessionId)
                .cnShellLeadingBarItem()
        }
        .id(sessionId)
    }
}

// MARK: List

struct AgentSessionList: View {
    let directory: AgentDirectory
    var open: (String) -> Void
    var create: () -> Void
    @State private var renaming: AgentSession?
    @State private var renameText = ""

    var body: some View {
        let sessions = directory.visibleSessions
        Group {
            if !directory.loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sessions.isEmpty {
                empty
            } else {
                List {
                    if let error = directory.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.cn(\.danger))
                    }
                    ForEach(sessions) { session in
                        Button { open(session.id) } label: {
                            // Relative times refresh on a 30 s tick.
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                AgentSessionRow(session: session, harness: directory.harness(session.harness),
                                                now: context.date, unread: AgentReadState.shared.isUnread(session))
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.cn(\.background))
                        .swipeActions(edge: .trailing) {
                            Button("Close", systemImage: "xmark", role: .destructive) {
                                Task { await directory.close(session.id) }
                            }
                            Button("Rename", systemImage: "pencil") {
                                renameText = session.title
                                renaming = session
                            }
                        }
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") {
                                renameText = session.title
                                renaming = session
                            }
                            Button("Close session", systemImage: "xmark.circle", role: .destructive) {
                                Task { await directory.close(session.id) }
                            }
                        }
                        .accessibilityIdentifier("agent.session.\(session.id)")
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .animation(CNTheme.shared.motion.move, value: sessions.map(\.id))
            }
        }
        .background(.cn(\.background))
        .alert("Rename session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let s = renaming { Task { await directory.rename(s.id, title: renameText) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 36, weight: .light)).foregroundStyle(.cn(\.textTertiary))
            Text("No agent sessions").font(.title3.weight(.semibold))
            Text("Start Claude Code, Codex or another agent on your Mac and follow it from here.")
                .font(.subheadline)
                .foregroundStyle(.cn(\.textSecondary))
                .multilineTextAlignment(.center)
            Button(action: create) {
                Label("New session", systemImage: "plus").font(.headline).padding(.horizontal, 8)
            }
            .buttonStyle(.glass)
            .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AgentSessionRow: View {
    var session: AgentSession
    var harness: Harness?
    var now: Date = Date()
    /// Unread as the user sees it (`AgentReadState`), not the host's raw count.
    var unread: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HarnessBadge(harnessId: session.harness, name: harness?.name ?? session.harness)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.title)
                        .font(.body.weight(unread ? .semibold : .medium))
                        .foregroundStyle(.cn(\.textPrimary))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(AgentFormat.relative(session.updatedAt, now: now))
                        .font(.subheadline)
                        .foregroundStyle(.cn(\.textTertiary))
                        .monospacedDigit()
                }
                HStack(alignment: .top, spacing: 6) {
                    Text(session.preview ?? session.cwd)
                        .font(.subheadline)
                        .foregroundStyle(.cn(\.textSecondary))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    status
                }
                Text([harness?.name ?? session.harness, session.cwd].joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.cn(\.textTertiary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(statusLabel)
    }

    @ViewBuilder private var status: some View {
        switch session.status {
        case .running:
            ProgressView().controlSize(.small).padding(.top, 2)
        case .waiting:
            Label("Approval", systemImage: "hand.raised.fill")
                .font(.caption.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.cn(\.attention))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(.cn(\.attention).opacity(0.14), in: .capsule)
        case .error:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.cn(\.danger)).padding(.top, 2)
        default:
            if unread {
                Circle().fill(.cn(\.ink)).frame(width: 9, height: 9).padding(.top, 6)
            }
        }
    }

    private var statusLabel: String {
        switch session.status {
        case .running: "Running"
        case .waiting: "Waiting for approval"
        case .error: "Error"
        case .closed: "Closed"
        default: unread ? "Unread" : "Idle"
        }
    }
}

// MARK: New session

struct NewSessionSheet: View {
    let directory: AgentDirectory
    var created: (AgentSession) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var harnessId: String?
    @State private var modelId: String?
    @State private var cwd = ""
    @State private var prompt = ""
    @State private var starting = false
    @State private var error: String?
    @FocusState private var promptFocused: Bool

    private var harness: Harness? { directory.harness(harnessId ?? "") }

    var body: some View {
        NavigationStack {
            Form {
                Section("Agent") {
                    ForEach(directory.harnesses) { h in
                        Button {
                            Haptics.select()
                            harnessId = h.id
                            modelId = h.models.first?.id
                        } label: {
                            HStack(spacing: 12) {
                                HarnessBadge(harnessId: h.id, name: h.name, size: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(h.name).foregroundStyle(.cn(\.textPrimary))
                                    if !h.available {
                                        Text("Not installed on this Mac").font(.caption).foregroundStyle(.cn(\.textTertiary))
                                    }
                                }
                                Spacer()
                                if h.id == harnessId { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.cn(\.ink)) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!h.available)
                        .opacity(h.available ? 1 : 0.5)
                        .accessibilityAddTraits(h.id == harnessId ? .isSelected : [])
                    }
                    if let harness, harness.models.count > 1 {
                        Picker("Model", selection: Binding(get: { modelId ?? "" }, set: { modelId = $0 })) {
                            ForEach(harness.models) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                Section {
                    TextField("~/src/project", text: $cwd)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    ForEach(directory.recentFolders.filter { $0 != cwd }, id: \.self) { folder in
                        Button { cwd = folder } label: {
                            Label(folder, systemImage: "clock.arrow.circlepath")
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(.cn(\.textSecondary))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                } header: {
                    Text("Folder")
                } footer: {
                    Text("The agent runs in this folder on your Mac.")
                }
                Section("First message") {
                    TextField("What should it work on?", text: $prompt, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($promptFocused)
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.cn(\.danger)) }
                }
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start", action: start)
                        .fontWeight(.semibold)
                        .disabled(harness?.available != true || starting)
                        .accessibilityIdentifier("agent.newSession.start")
                }
            }
            .onAppear(perform: applyDefaults)
            .onChange(of: directory.harnesses) { applyDefaults() }
        }
        .presentationDetents([.large])
    }

    /// First available harness and the most recent folder, once known
    /// (the sheet can open before the host's lists arrive).
    private func applyDefaults() {
        if harnessId == nil, let first = directory.harnesses.first(where: \.available) {
            harnessId = first.id
            modelId = first.models.first?.id
        }
        if cwd.isEmpty { cwd = directory.recentFolders.first ?? "" }
    }

    private func start() {
        guard let harness else { return }
        starting = true
        let folder = cwd.trimmingCharacters(in: .whitespaces)
        let first = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let session = try await directory.create(AgentCreateParams(
                    harness: harness.id, cwd: folder.isEmpty ? nil : folder, model: modelId, prompt: first.isEmpty ? nil : first))
                Haptics.success()
                created(session)
            } catch {
                self.error = AgentDirectory.describe(error)
                starting = false
            }
        }
    }
}
#endif
