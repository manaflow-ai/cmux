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
    /// The tallest viewport seen: the reserve below the last prompt. Transient
    /// bars (approval card, keyboard) must not shrink content, or the scroll
    /// offset would be clamped in one frame.
    @State private var reserveHeight: CGFloat = 0
    /// Set on send until the scroll reaches the new prompt; while set, growth
    /// does not unpin.
    @State private var followingSend = false
    /// Latest scroll metrics, unobserved (written every scroll frame).
    @State private var latest = LatestMetrics()
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmingClose = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(connection: HostConnection, sessionId: String, onClosed: (() -> Void)? = nil) {
        self.connection = connection
        let model = AgentChatModel(connection: connection, sessionId: sessionId)
        self.onClosed = onClosed
        #if DEBUG
        _draft = State(initialValue: AgentDebug.draft ?? "")
        model.forceOpen = AgentDebug.expandAll
        #endif
        _model = State(initialValue: model)
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
        shaper.keepOpenTurns = model.finishedInView
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
                // The last turn reserves a full screen below its prompt, laid
                // out in the same pass as the rows (no one-frame lag).
                TranscriptLayout(tailMinHeight: reserveHeight) { rowViews(shaped) }
                    .padding(.top, 4)
                    .frame(minHeight: viewportHeight, alignment: .top)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) { rowViews(shaped) }
                    .padding(.top, 4)
            }
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.top, for: .alignment)
        // Size changes keep the top still; a pinned reader is then eased back
        // to the bottom (below) so the transcript moves with the keyboard and
        // the growing composer instead of jumping ahead of them.
        .defaultScrollAnchor(.top, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        // The visible height between the bars, for top-aligning short transcripts.
        // (The proxy size already excludes the nav bar and composer insets.)
        .onGeometryChange(for: CGFloat.self) { p in p.size.height } action: { h in
            viewportHeight = max(0, h - 8)
            reserveHeight = max(reserveHeight, viewportHeight)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { old, new in
            // Rotation or a split resize: start over from the current viewport.
            if abs(old - new) > 1 { reserveHeight = viewportHeight }
        }
        // The first measurement precedes the composer inset; re-seed once loaded.
        .onChange(of: model.loaded) { reserveHeight = viewportHeight }
        .onScrollPhaseChange { _, phase in
            userScrolling = phase == .interacting || phase == .decelerating || phase == .tracking
        }
        .onScrollGeometryChange(for: ScrollMetrics.self) { g in
            ScrollMetrics(offset: g.contentOffset.y, content: g.contentSize.height,
                          inset: g.contentInsets.bottom, container: g.containerSize.height)
        } action: { old, m in
            latest.value = m
            let near = m.maxOffset - m.offset < 48
            let contentGrew = abs(m.content - old.content) > 0.5
            let framed = abs(m.inset - old.inset) > 0.5 || abs(m.container - old.container) > 0.5
            if followingSend, m.offset >= m.maxOffset - 0.5 { followingSend = false }
            if contentGrew || framed {
                // Size changed (reply text, keyboard, composer, a new row).
                guard pinned, !userScrolling else { return }
                // A pinned reader follows growth with an eased scroll (a glide
                // per new line, never a snap) until they scroll away.
                if m.offset < m.maxOffset - 0.5 {
                    // First content (opening the session) lands without motion;
                    // a send rises on the move spring; other growth glides.
                    // An explicit offset, because re-setting the same
                    // `.bottom` edge position is ignored.
                    let first = old.content < 1 || old.container < 1
                    let animation: Animation? = reduceMotion || first ? nil : followingSend ? motion.move : .smooth(duration: 0.3)
                    withAnimation(animation) { position.scrollTo(y: m.maxOffset) }
                }
            } else if userScrolling {
                // Only the reader's own scrolling pins or unpins.
                if pinned != near { pinned = near }
            } else if near, !pinned {
                pinned = true
            }
        }
        .onChange(of: model.sendTick) {
            // The new prompt rises to the top of the screen and its reply
            // grows into the space reserved below it. By identity, so the
            // target resolves against the final layout.
            pinned = true
            followingSend = true
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
        let lastUser = rows.last { if case .user = $0 { true } else { false } }?.id
        ForEach(rows) { row in
            ChatRowView(row: row, model: model)
                .padding(.top, row.topSpacing)
                .padding(.horizontal, 16)
                .transition(transition(for: row))
                .id(row.id)
                .layoutValue(key: TurnStartKey.self, value: row.id == lastUser)
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
            withAnimation(motion.move) { position.scrollTo(y: latest.value.maxOffset) }
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
        // Not in an animation transaction: the new rows and the reserve land
        // in one layout, then the scroll eases to them (see the geometry
        // handler). The bubble animates its own entrance.
        model.submit(text, attachments: files)
        // Keep typing: the composer stays focused after a send (the row
        // insertion can otherwise take first responder away for a turn).
        Task { @MainActor in composerFocused = true }
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

/// Marks the row that starts the last turn.
struct TurnStartKey: LayoutValueKey {
    static let defaultValue = false
}

/// A leading-aligned vertical stack (no spacing; rows carry their own) whose
/// height leaves at least `tailMinHeight` from the top of the marked row to
/// the end: the screen reserved for the last turn's reply.
struct TranscriptLayout: Layout {
    var tailMinHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        var y: CGFloat = 0
        var tailTop: CGFloat?
        for v in subviews {
            if v[TurnStartKey.self] { tailTop = y }
            y += v.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        if let tailTop { y = max(y, tailTop + tailMinHeight) }
        return CGSize(width: width, height: y)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for v in subviews {
            let size = v.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            v.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: size.height))
            y += size.height
        }
    }
}

final class LatestMetrics {
    var value = ScrollMetrics(offset: 0, content: 0, inset: 0, container: 0)
}

struct ScrollMetrics: Equatable {
    var offset: CGFloat
    var content: CGFloat
    var inset: CGFloat
    var container: CGFloat
    var maxOffset: CGFloat { content + inset - container }
}

#if DEBUG
/// Launch-time knobs for validation captures (DEBUG only).
enum AgentDebug {
    static let env = ProcessInfo.processInfo.environment
    /// Open every disclosure: screenshots of every transcript item kind.
    static let expandAll = env["CMUX_NEXT_AGENT_EXPAND"] == "1"
    /// Push this session at launch.
    static let openSession = env["CMUX_NEXT_AGENT_SESSION"]
    /// Prefill the composer (`~~` stands for a newline).
    static let draft = env["CMUX_NEXT_AGENT_DRAFT"]?.replacingOccurrences(of: "~~", with: "\n")
    /// Present the new-session sheet at launch.
    static let newSession = env["CMUX_NEXT_AGENT_NEW"] == "1"
}
#endif
#endif
