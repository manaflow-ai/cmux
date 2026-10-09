#if os(iOS)
import CNCore
import CNDesign
import CNTransport
import SwiftUI

/// One agent session: the transcript, the pinned approval, and the floating
/// composer. Lives inside a NavigationStack (pushed by `AgentsRoot`, or
/// wrapped by the public `AgentChatView`).
struct AgentChatScreen: View {
    let connection: HostConnection
    @State private var model: AgentChatModel
    var onClosed: (() -> Void)?

    @State private var draft = ""
    @State private var attachments: [ComposerAttachment] = []
    @FocusState private var composerFocused: Bool
    @State private var pinned = true
    @State private var userScrolling = false
    @State private var viewportHeight: CGFloat = 0
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmingClose = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(connection: HostConnection, sessionId: String, onClosed: (() -> Void)? = nil) {
        self.connection = connection
        _model = State(initialValue: AgentChatModel(connection: connection, sessionId: sessionId))
        self.onClosed = onClosed
        #if DEBUG
        _draft = State(initialValue: AgentDebug.draft ?? "")
        #endif
    }

    private var motion: CNMotion { CNTheme.shared.motion }

    var body: some View {
        content
            .background(.cn(\.background))
            .navigationTitle(model.session?.title ?? "Agent")
            .navigationSubtitle(subtitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { sessionMenu } }
            .task { await model.listen() }
            .task(id: connection.generation) { await model.reload() }
            .alert("Rename session", isPresented: $renaming) {
                TextField("Title", text: $renameText)
                Button("Rename") { model.rename(renameText) }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Close this session?", isPresented: $confirmingClose, titleVisibility: .visible) {
                Button("Close session", role: .destructive) {
                    Task {
                        await model.close()
                        onClosed?()
                        dismiss()
                    }
                }
            } message: {
                Text("The agent stops and the session leaves the list.")
            }
    }

    private var subtitle: String {
        [model.harness?.name, model.modelName].compactMap { $0 }.joined(separator: " · ")
    }

    /// One container for every state, so the composer (and its focus)
    /// survives the switch from the empty greeting to the first turn.
    private var content: some View {
        transcript
            .overlay {
                if !model.loaded {
                    ProgressView()
                } else if !model.hasTurns {
                    emptyState.transition(.opacity)
                }
            }
            .animation(motion.fade, value: model.hasTurns)
    }

    // MARK: Transcript

    private var rows: [ChatRow] {
        var shaper = TranscriptShaper(expanded: model.expanded, live: model.isLive, sendStates: model.sendStates)
        #if DEBUG
        shaper.expandAll = AgentDebug.expandAll
        #endif
        return model.hasTurns ? shaper.rows(for: model.items) : []
    }

    private var transcript: some View {
        ScrollView {
            let shaped = rows
            // Exact heights for ordinary sessions: a lazy stack estimates
            // unrealized rows, which makes bottom anchoring land short and
            // jump. Very long transcripts trade that for laziness.
            if shaped.count <= 160 {
                // Short transcripts sit at the top, as in the iOS AI apps.
                VStack(alignment: .leading, spacing: 0) { rowViews(shaped) }
                    .padding(.top, 4)
                    .frame(minHeight: viewportHeight, alignment: .top)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) { rowViews(shaped) }.padding(.top, 4)
            }
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        // Pinned to the bottom, new text, the keyboard and a growing composer
        // push the transcript up; scrolled back, the reader's place stays put.
        .defaultScrollAnchor(pinned ? .bottom : .top, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        // The visible height between the bars, for top-aligning short transcripts.
        // (The proxy size already excludes the nav bar and composer insets.)
        .onGeometryChange(for: CGFloat.self) { p in p.size.height } action: { h in
            viewportHeight = max(0, h - 8)
        }
        .onScrollPhaseChange { _, phase in
            userScrolling = phase == .interacting || phase == .decelerating || phase == .tracking
        }
        .onScrollGeometryChange(for: ScrollMetrics.self) { g in
            ScrollMetrics(offset: g.contentOffset.y,
                          maxOffset: g.contentSize.height + g.contentInsets.bottom - g.containerSize.height)
        } action: { _, m in
            let near = m.maxOffset - m.offset < 48
            if userScrolling {
                if pinned != near { pinned = near }
            } else if pinned && m.offset < m.maxOffset - 0.5 {
                // Content or insets changed under a pinned reader: stay at the bottom.
                position.scrollTo(edge: .bottom)
            } else if near && !pinned {
                pinned = true
            }
        }
        .onChange(of: model.sendTick) {
            pinned = true
            withAnimation(reduceMotion ? nil : motion.move) { position.scrollTo(edge: .bottom) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
                .overlay(alignment: .top) {
                    if !pinned {
                        scrollToBottomButton
                            .offset(y: -48)
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                    }
                }
                .animation(motion.appear, value: pinned)
        }
    }

    @ViewBuilder private func rowViews(_ rows: [ChatRow]) -> some View {
        ForEach(rows) { row in
            ChatRowView(row: row, model: model)
                .padding(.top, row.topSpacing)
                .padding(.horizontal, 16)
                .transition(transition(for: row))
        }
        Color.clear.frame(height: 12)
    }

    private func transition(for row: ChatRow) -> AnyTransition {
        if reduceMotion { return .opacity }
        if case .user = row {
            return .asymmetric(insertion: .offset(y: 24).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)),
                               removal: .opacity)
        }
        return .opacity
    }

    private var scrollToBottomButton: some View {
        Button {
            Haptics.select()
            pinned = true
            withAnimation(motion.move) { position.scrollTo(edge: .bottom) }
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.cn(\.textPrimary))
                .frame(width: 38, height: 38)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scroll to bottom")
        .accessibilityIdentifier("agent.scrollToBottom")
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        let pending = model.pendingPermission
        let slash = SlashMenu.matches(draft, in: model.commands)
        return VStack(spacing: 8) {
            if let pending {
                PermissionCard(pending: pending) { option in
                    withAnimation(motion.move) { model.answer(pending.item, option: option) }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier("agent.permissionCard")
            }
            if !model.queue.isEmpty {
                QueuedStrip(queue: model.queue) { id in withAnimation(motion.move) { model.removeQueued(id) } }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !slash.isEmpty {
                SlashMenu(commands: slash) { c in
                    Haptics.select()
                    draft = (c.name.hasPrefix("/") ? c.name : "/" + c.name) + " "
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)))
            }
            GlassEffectContainer {
                Composer(
                    text: $draft,
                    attachments: $attachments,
                    placeholder: placeholder,
                    running: model.isLive,
                    models: model.harness?.models ?? [],
                    modes: model.harness?.modes ?? [],
                    modelId: model.session?.model,
                    modeId: model.session?.mode,
                    focus: $composerFocused,
                    onSend: send,
                    onStop: { model.cancel() },
                    onModel: { model.setModel($0) },
                    onMode: { model.setMode($0) }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(reduceMotion ? nil : motion.move, value: pending?.item.id)
        .animation(motion.appear, value: slash.count)
        .animation(motion.move, value: model.queue.count)
    }

    private var placeholder: String {
        model.isLive ? "Queue a follow-up" : "Message \(model.harness?.name ?? "the agent")"
    }

    private func send() {
        let text = draft, files = attachments
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else { return }
        draft = ""
        attachments = []
        withAnimation(reduceMotion ? nil : motion.appear) { model.submit(text, attachments: files) }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            if let harness = model.harness {
                HarnessBadge(harnessId: harness.id, name: harness.name, size: 52)
                    .padding(.bottom, 6)
            }
            Text(greeting)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.cn(\.textPrimary))
            if let cwd = model.session?.cwd {
                Label(cwd, systemImage: "folder")
                    .font(.subheadline)
                    .foregroundStyle(.cn(\.textSecondary))
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { composerFocused = false }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return "\(part). What should \(model.harness?.name ?? "the agent") work on?"
    }

    // MARK: Menu

    private var sessionMenu: some View {
        Menu {
            Button("Rename", systemImage: "pencil") {
                renameText = model.session?.title ?? ""
                renaming = true
            }
            if let harness = model.harness, !harness.models.isEmpty {
                Picker(selection: Binding(get: { model.session?.model ?? "" }, set: { model.setModel($0) })) {
                    ForEach(harness.models) { Text($0.name).tag($0.id) }
                } label: {
                    Label("Model", systemImage: "cpu")
                }
                .pickerStyle(.menu)
            }
            if let harness = model.harness, !harness.modes.isEmpty {
                Picker(selection: Binding(get: { model.session?.mode ?? "" }, set: { model.setMode($0) })) {
                    ForEach(harness.modes) { Text($0.name).tag($0.id) }
                } label: {
                    Label("Mode", systemImage: "slider.horizontal.3")
                }
                .pickerStyle(.menu)
            }
            if let cwd = model.session?.cwd {
                Button("Copy folder path", systemImage: "folder") { UIPasteboard.general.string = cwd }
            }
            Divider()
            Button("Close session", systemImage: "xmark.circle", role: .destructive) { confirmingClose = true }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("Session options")
        .accessibilityIdentifier("agent.sessionMenu")
    }
}

struct ScrollMetrics: Equatable {
    var offset: CGFloat
    var maxOffset: CGFloat
}

#if DEBUG
/// Launch-time knobs for validation captures (DEBUG only).
enum AgentDebug {
    static let env = ProcessInfo.processInfo.environment
    /// Open every disclosure: screenshots of every transcript item kind.
    static let expandAll = env["CMUX_NEXT_AGENT_EXPAND"] == "1"
    /// Push this session at launch.
    static let openSession = env["CMUX_NEXT_AGENT_SESSION"]
    /// Prefill the composer.
    static let draft = env["CMUX_NEXT_AGENT_DRAFT"]?.replacingOccurrences(of: "\\n", with: "\n")
    /// Present the new-session sheet at launch.
    static let newSession = env["CMUX_NEXT_AGENT_NEW"] == "1"
}
#endif
#endif
