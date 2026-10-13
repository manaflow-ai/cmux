#if os(iOS)
import CmuxAgentQuestion
import CnxArtifacts
import CnxDesign
import CnxDiff
import CnxMarkdown
import SwiftUI
import UIKit

/// View state of one open agent chat, shared by its transcript and its
/// bottom stack. The pushed `AgentChatScreen` owns one; a workspace tab
/// (CmuxTabsKit) keeps one per tab so the transcript (the tab's page) and
/// the composer (the tab's accessory row above the toolbar) are separate
/// views that act as one screen.
@MainActor
@Observable
public final class AgentChatSurface {
    public var text = ""
    var attachments: [AgentAttachment] = []
    /// The transcript's scroll position. Writes that change nothing are
    /// dropped: SwiftUI writes the resolved position back through the
    /// binding, and an unconditional invalidation there can feed back into
    /// another scroll request without end (seen with live sessions).
    var position: ScrollPosition {
        get {
            access(keyPath: \.position)
            return storedPosition
        }
        set {
            guard newValue != storedPosition else { return }
            withMutation(keyPath: \.position) { storedPosition = newValue }
        }
    }
    @ObservationIgnored private var storedPosition = ScrollPosition(edge: .bottom)
    public internal(set) var following = true
    var showJump = false
    var diffRoute: DiffRoute?
    /// Subagents, a subagent, checkpoints or the handoff, pushed over the chat.
    public var parityRoute: AgentParityRoute?
    /// The session's artifacts browser (a sheet).
    public var showArtifacts = false
    public let artifacts = ArtifactsBrowserState()
    // DEBUG demo hooks for the parity screens (the screens act on them through their own paths).
    var demoCheckpointRestore: String?
    var demoConfirmRestore = 0
    var demoHandoffTarget: String?
    var demoHandoffFill: String?
    var demoHandoffStart = 0
    @ObservationIgnored private var lastDemoSerial = -1
    var replyInsteadOfPermission = false
    /// Mirrors the composer's focus (the composer's `@FocusState` follows it).
    public var composerFocused = false
    /// Screen y of the top of the floating bottom stack (tab mode), so the
    /// transcript's bottom margin follows the composer and the keyboard.
    public internal(set) var bottomStackTop: CGFloat?

    public init() {}

    struct DiffRoute: Identifiable, Hashable {
        let changes: DiffChangeSet
        let fileID: String?
        var id: String { changes.id + (fileID ?? "") }
    }

    /// Opens the session's combined changes (title menu "Changes").
    public func openAllChanges(of store: AgentChatStore) {
        let files = store.turns.compactMap(\.changeSet).flatMap(\.files)
        guard !files.isEmpty else { return }
        var unique: [String: DiffFile] = [:]
        for file in files { unique[file.id] = file }
        let ordered = files.map(\.id).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.compactMap { unique[$0] }
        diffRoute = DiffRoute(changes: DiffChangeSet(id: "session", title: "Changes", subtitle: store.summary.branch ?? "working tree", files: ordered), fileID: nil)
    }

    public func scrollToBottom(animated: Bool = true) {
        following = true
        if animated {
            withAnimation(.smooth(duration: 0.35)) { position.scrollTo(edge: .bottom) }
        } else {
            position.scrollTo(edge: .bottom)
        }
    }

    /// The transcript as Markdown (Share transcript).
    public static func transcriptText(_ store: AgentChatStore) -> String {
        store.turns.map { "> \($0.prompt)\n\n\($0.answerMarkdown)" }.joined(separator: "\n\n---\n\n")
    }

    // MARK: Demo

    /// DEBUG demo commands (`DemoDirector`) run through the same state the
    /// user's input changes.
    func run(_ command: DemoDirector.Command, store: AgentChatStore) {
        // Pushed screens stop updating under the one on top, so every chat
        // screen listens and the first to see a command runs it.
        let serial = DemoDirector.shared.serial
        guard serial != lastDemoSerial else { return }
        lastDemoSerial = serial
        switch command {
        case .chatSend(let prompt):
            Task {
                composerFocused = true
                try? await Task.sleep(for: .milliseconds(500))
                for character in prompt {
                    text.append(character)
                    try? await Task.sleep(for: .milliseconds(28))
                }
                try? await Task.sleep(for: .milliseconds(400))
                store.send(prompt: text)
                text = ""
                composerFocused = false
            }
        case .chatScroll(let toTop):
            following = !toTop
            withAnimation(.smooth(duration: 0.9)) { position.scrollTo(edge: toTop ? .top : .bottom) }
        case .chatPermission(let kind):
            if let permission = store.pendingPermission,
               let option = permission.request.options.first(where: { $0.kind.rawValue == kind }) {
                withAnimation(.cnxSmooth) { store.respond(to: permission.request, option: option) }
            }
        case .chatOpenChanges:
            if let changes = store.turns.last(where: { $0.changeSet != nil })?.changeSet {
                diffRoute = DiffRoute(changes: changes, fileID: nil)
            }
        case .chatOpenFirstFile:
            if let changes = store.turns.last(where: { $0.changeSet != nil })?.changeSet, let file = changes.files.dropFirst().first ?? changes.files.first {
                diffRoute = DiffRoute(changes: changes, fileID: file.id)
            }
        case .navigateBack:
            if diffRoute != nil { diffRoute = nil }
        case .chatOpenArtifacts:
            artifacts.path = []
            showArtifacts = true
        case .artifactsFilter(let name):
            if let filter = ArtifactFilter(rawValue: name) { withAnimation(.snappy) { artifacts.filter = filter } }
        case .artifactsLayout(let grid):
            artifacts.grid = grid
        case .artifactsOpen(let reference):
            let collected = SessionArtifacts.collect(turns: store.turns, subagents: store.subagents, cwd: store.summary.cwd)
            if let artifact = collected.artifacts.first(where: { $0.reference == reference }) { artifacts.path = [artifact] }
        case .artifactsSource(let on):
            artifacts.showSource = on
        case .artifactsBack:
            if !artifacts.path.isEmpty { artifacts.path.removeLast() }
        case .artifactsClose:
            showArtifacts = false
        case .chatOpenParity(let route):
            switch route {
            case "subagents": parityRoute = .subagents
            case "checkpoints": parityRoute = .checkpoints
            case "handoff": parityRoute = .handoff
            default: parityRoute = store.subagents.first(where: { $0.name == route }).map { .subagent($0.id) }
            }
        case .parityClose:
            parityRoute = nil
        case .checkpointRestore(let id):
            demoCheckpointRestore = id
        case .checkpointConfirm:
            demoConfirmRestore += 1
        case .handoffPick(let id):
            demoHandoffTarget = id
        case .handoffFill(let reference):
            demoHandoffFill = reference
        case .handoffStart:
            demoHandoffStart += 1
        default:
            break
        }
    }
}

/// SPEC 6: the agent chat. Transcript with follow mode and jump-to-bottom,
/// composer (or the permission action bar), toolbar title menu and actions.
public struct AgentChatScreen: View {
    let store: AgentChatStore
    @State private var surface = AgentChatSurface()

    public init(store: AgentChatStore) {
        self.store = store
    }

    public var body: some View {
        AgentChatTranscript(store: store, surface: surface)
            .safeAreaInset(edge: .bottom, spacing: 0) { AgentChatBottomStack(store: store, surface: surface) }
            .background(Color.cnxBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .toolbar(.hidden, for: .tabBar)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Menu {
                Button("Rename", systemImage: "pencil") {}
                Button("Open terminal", systemImage: "apple.terminal") {}
                Button("Files and artifacts", systemImage: "folder") { surface.showArtifacts = true }
                Button("Changes", systemImage: "plus.forwardslash.minus") { surface.openAllChanges(of: store) }
                AgentParityMenuItems(store: store, surface: surface)
                Button("Copy session ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = store.summary.id }
                if !store.modes.isEmpty {
                    Section("Mode") {
                        Picker("Mode", selection: Binding(get: { store.currentModeID ?? "" }, set: { store.setMode($0) })) {
                            ForEach(store.modes) { Text($0.name).tag($0.id) }
                        }
                    }
                }
            } label: {
                VStack(spacing: 1) {
                    Text(store.summary.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text("\(store.summary.agentName) · \(store.summary.workspaceTitle)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: 240)
            }
            .accessibilityLabel(Text("\(store.summary.name), \(store.summary.agentName) in \(store.summary.workspaceTitle)"))
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("New session", systemImage: "square.and.pencil") {}
            Menu {
                Button("Files and artifacts", systemImage: "folder") { surface.showArtifacts = true }
                ShareLink(item: AgentChatSurface.transcriptText(store)) { Label("Share transcript", systemImage: "square.and.arrow.up") }
                Button("Archive", systemImage: "archivebox") {}
                Button("Stop agent", systemImage: "stop.circle", role: .destructive) { store.cancel() }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More")
        }
    }

    private var statusColor: Color {
        switch store.summary.status {
        case .running: .cnxWarning
        case .waiting: .cnxWarning
        case .disconnected, .closed: Color(uiColor: .tertiaryLabel)
        default: .cnxSuccess
        }
    }
}

/// The transcript of an agent chat (follow mode, jump detection, diff
/// pushes, demo commands). Pushed: under the system toolbar with the bottom
/// stack in its safe area inset. In a workspace tab: full screen under the
/// tab toolbar, with `topInset` / `bottomInset` for the chrome.
public struct AgentChatTranscript: View {
    let store: AgentChatStore
    @Bindable var surface: AgentChatSurface
    var topInset: CGFloat?
    var bottomInset: CGFloat?
    var onUserScroll: ((CGFloat) -> Void)?
    @State private var warningTrigger = 0
    @State private var userScrolling = false
    private let director = DemoDirector.shared

    /// `topInset` / `bottomInset`: explicit content margins when the chat
    /// draws under foreign chrome (nil: the safe area). `onUserScroll`
    /// receives finger travel while the user drags (positive = finger down).
    public init(store: AgentChatStore, surface: AgentChatSurface, topInset: CGFloat? = nil, bottomInset: CGFloat? = nil,
                onUserScroll: ((CGFloat) -> Void)? = nil) {
        self.store = store
        self.surface = surface
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.onUserScroll = onUserScroll
    }

    public var body: some View {
        ScrollView {
            // A plain VStack: with LazyVStack the content height came from
            // estimates (769 pt measured vs 1450-1538 pt estimated) and the
            // bottom anchor settled past the content on iOS 26, leaving the
            // page blank after a workspace opened or a tab zoomed in.
            VStack(alignment: .leading, spacing: 0) {
                if store.turns.isEmpty {
                    emptyState
                } else {
                    if let first = store.turns.first {
                        Text("Session started \(first.promptAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                            .padding(.bottom, 20)
                    }
                    ForEach(store.turns) { turn in
                        TurnView(turn: turn, store: store, isLast: turn.id == store.turns.last?.id, surface: surface)
                            .padding(.bottom, 24)
                            .id(turn.id)
                    }
                }
            }
            .padding(.horizontal, 20)
            .scrollTargetLayout()
        }
        .contentMargins(.top, topInset ?? 0, for: .scrollContent)
        .contentMargins(.bottom, bottomInset ?? 0, for: .scrollContent)
        .contentMargins(.bottom, bottomInset ?? 0, for: .scrollIndicators)
        .scrollPosition($surface.position)
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY
        } action: { _, distance in
            let away = distance > 80
            if surface.showJump != away { withAnimation(.cnxSnap) { surface.showJump = away } }
            if !away { surface.following = true }
        }
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { old, new in
            if userScrolling { onUserScroll?(old - new) }
        }
        .onScrollPhaseChange { _, phase, context in
            userScrolling = phase == .interacting
            if phase == .interacting || phase == .decelerating {
                let geometry = context.geometry
                let distance = geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY
                surface.following = distance <= 80
            }
        }
        .onChange(of: store.revision) {
            if surface.following { surface.position.scrollTo(edge: .bottom) }
        }
        .onChange(of: bottomInset) {
            if surface.following { surface.position.scrollTo(edge: .bottom) }
        }
        .environment(\.openDiff, OpenDiffAction { changes, file in surface.diffRoute = AgentChatSurface.DiffRoute(changes: changes, fileID: file) })
        .navigationDestination(item: $surface.diffRoute) { route in
            if let file = route.fileID {
                DiffFileScreen(changeSet: route.changes, fileID: file)
            } else {
                DiffChangesScreen(changeSet: route.changes)
            }
        }
        .navigationDestination(item: $surface.parityRoute) { route in
            AgentParityDestination(route: route, store: store, surface: surface)
        }
        .sheet(isPresented: $surface.showArtifacts) {
            SessionArtifactsSheet(store: store, surface: surface)
        }
        .sensoryFeedback(.warning, trigger: warningTrigger)
        .onChange(of: store.pendingPermission?.request.id) { _, new in if new != nil { warningTrigger += 1 } }
        .onChange(of: store.pendingQuestion?.id) { _, new in if new != nil { warningTrigger += 1 } }
        .onChange(of: director.serial) {
            if let command = director.command { surface.run(command, store: store) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkle")
                .font(.system(size: 22))
                .frame(width: 48, height: 48)
                .background(Color.cnxSurfaceRaised, in: .circle)
            Text("What should \(store.summary.agentName) do?").font(.title3.weight(.semibold))
            Text("\(store.summary.workspaceTitle) on \(store.summary.macName)").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 220)
    }
}

/// Jump-to-bottom circle over the composer, or the permission action bar
/// in the composer's place (SPEC 6.5, 6.9).
public struct AgentChatBottomStack: View {
    let store: AgentChatStore
    @Bindable var surface: AgentChatSurface
    @FocusState private var composerFocused: Bool

    public init(store: AgentChatStore, surface: AgentChatSurface) {
        self.store = store
        self.surface = surface
    }

    public var body: some View {
        VStack(spacing: 12) {
            if surface.showJump {
                Button {
                    surface.scrollToBottom()
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .overlay {
                            if store.isRunning {
                                PulsingRing()
                            }
                        }
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
                .accessibilityLabel("Jump to bottom")
            }
            VStack(spacing: 12) {
                if let error = store.clientError {
                    Button {
                        withAnimation(.cnxSmooth) { store.clientError = nil }
                    } label: {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity.combined(with: .offset(y: 8)))
                    .accessibilityHint("Dismiss")
                }
                if let permission = store.pendingPermission, !surface.replyInsteadOfPermission {
                    PermissionActionBar(request: permission.request) { option in
                        withAnimation(.cnxSmooth) { store.respond(to: permission.request, option: option) }
                    } replyInstead: {
                        withAnimation(.cnxSmooth) { surface.replyInsteadOfPermission = true }
                        surface.composerFocused = true
                    }
                    .padding(12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 28, style: .continuous))
                    .padding(.horizontal, 12)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 16)), removal: .opacity))
                } else {
                    ChatComposer(store: store, text: $surface.text, attachments: $surface.attachments, focus: $composerFocused, collapsible: !store.turns.isEmpty)
                        .transition(.opacity)
                }
            }
            // The transcript's bottom margin follows this top. The jump
            // button above is excluded: it appears when the transcript is
            // more than 80 pt from the bottom, and counting it moved the
            // margin, which moved the distance, which toggled the button
            // (a layout loop that flickered and could hang after a tab zoom).
            .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY }) { surface.bottomStackTop = $0 }
        }
        .padding(.bottom, 8)
        .animation(.cnxSmooth, value: store.pendingPermission?.request.id)
        .onChange(of: store.pendingPermission?.request.id) { surface.replyInsteadOfPermission = false }
        .onChange(of: surface.composerFocused) { _, focused in if composerFocused != focused { composerFocused = focused } }
        .onChange(of: composerFocused) { _, focused in if surface.composerFocused != focused { surface.composerFocused = focused } }
    }
}

struct PulsingRing: View {
    @State private var on = false

    var body: some View {
        Circle()
            .strokeBorder(Color.primary, lineWidth: 2)
            .opacity(on ? 0.9 : 0.2)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// One turn: user bubble, the agent's rows, working label, changes card, actions.
struct TurnView: View {
    let turn: AgentTurn
    let store: AgentChatStore
    let isLast: Bool
    var surface: AgentChatSurface?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            UserBubble(turn: turn, isLast: isLast) { store.send(prompt: $0) }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .transition(.asymmetric(insertion: .offset(y: 24).combined(with: .scale(scale: 0.96)).combined(with: .opacity), removal: .opacity))
            VStack(alignment: .leading, spacing: 10) {
                let rows = turn.rows
                ForEach(rows) { row in
                    rowView(row, isLastRow: row.id == rows.last?.id)
                        .transition(.opacity.animation(.easeOut(duration: 0.15)))
                }
                if turn.status == .running, showsWorking(rows) {
                    WorkingLabel(store.pendingPermission != nil ? "Waiting for permission" : (store.pendingQuestion != nil ? "Waiting for your answer" : "Working"),
                                 since: turn.startedAt)
                        .frame(minHeight: 28)
                }
                if turn.status != .running, let changes = turn.changeSet {
                    EditedFilesCard(changeSet: changes).padding(.top, 4)
                }
                switch turn.status {
                case .cancelled:
                    Text("Stopped").font(.footnote).foregroundStyle(.tertiary)
                case .failed:
                    FailureCard(title: "Agent stopped", message: turn.errorText ?? "The turn ended with an error.") {
                        store.send(prompt: turn.prompt)
                    }
                case .completed:
                    AnswerActionRow(turn: turn, isLast: isLast) { store.send(prompt: turn.prompt) }
                case .running:
                    EmptyView()
                }
            }
        }
    }

    private func showsWorking(_ rows: [TurnRow]) -> Bool {
        guard let last = rows.last else { return true }
        switch last {
        case .message: return false
        case .thought: return false
        default: return true
        }
    }

    @ViewBuilder
    private func rowView(_ row: TurnRow, isLastRow: Bool) -> some View {
        switch row {
        case .message(_, let markdown):
            StreamingMarkdown(markdown: markdown, isStreaming: turn.status == .running && isLastRow)
        case .thought(_, let text):
            ThoughtRow(text: text, isLive: turn.status == .running && isLastRow)
        case .tool(let call):
            ToolRowView(call: call)
        case .toolGroup(_, let calls):
            ToolGroupView(calls: calls, turnRunning: turn.status == .running)
        case .edit(let call):
            if call.isRunning {
                ToolRowView(call: call)
            } else {
                DiffSnippet(call: call, changeSet: turn.changeSet ?? DiffChangeSet(id: call.id, title: "Changes", subtitle: "", files: []))
            }
        case .plan(_, let entries):
            PlanCard(entries: entries)
        case .permission(let record):
            PermissionCard(record: record, agentName: store.summary.agentName)
        case .question(let id):
            if let question = turn.question(id) {
                QuestionCard(question: question) { store.answer(question, with: $0) }
            }
        case .subagents(_, let ids):
            SubagentGroupCard(ids: ids, store: store) { surface?.parityRoute = .subagent($0) }
        }
    }
}

/// Title-menu entries for the parity screens (pushed chat and workspace tab).
public struct AgentParityMenuItems: View {
    let store: AgentChatStore
    let surface: AgentChatSurface

    public init(store: AgentChatStore, surface: AgentChatSurface) {
        self.store = store
        self.surface = surface
    }

    public var body: some View {
        Section {
            Button(store.subagents.isEmpty ? "Subagents" : "Subagents (\(store.subagents.count))", systemImage: "person.2.wave.2") {
                surface.parityRoute = .subagents
            }
            Button("Checkpoints", systemImage: "clock.arrow.circlepath") { surface.parityRoute = .checkpoints }
            Button("Continue in…", systemImage: "arrow.triangle.branch") { surface.parityRoute = .handoff }
        }
    }
}

/// Committed blocks render once; only the tail block re-renders each tick (SPEC 6.3).
struct StreamingMarkdown: View {
    let markdown: String
    let isStreaming: Bool

    var body: some View {
        MarkdownView(MarkdownDocument(parsing: markdown), isStreaming: isStreaming)
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = markdown }
                ShareLink(item: markdown) { Label("Share", systemImage: "square.and.arrow.up") }
            }
    }
}

/// SPEC 4.4 user bubble with a timestamp-headed context menu and select-text sheet.
struct UserBubble: View {
    let turn: AgentTurn
    let isLast: Bool
    let resend: (String) -> Void
    @State private var selecting = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !turn.attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(turn.attachments) { attachment in
                        AttachmentThumb(attachment: attachment) {}
                            .allowsHitTesting(false)
                    }
                }
            }
            Text(turn.prompt)
                .font(.body)
                .lineSpacing(4)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Color.cnxBubble, in: .rect(cornerRadius: 20, style: .continuous))
                .contentShape(.contextMenuPreview, .rect(cornerRadius: 20, style: .continuous))
                .contextMenu {
                    Section(turn.promptAt.formatted(.dateTime.weekday(.wide).hour().minute())) {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = turn.prompt }
                        Button("Select text", systemImage: "selection.pin.in.out") { selecting = true }
                        if isLast {
                            Button("Edit and resend", systemImage: "pencil") { resend(turn.prompt) }
                        }
                        ShareLink(item: turn.prompt) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                }
        }
        .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in width * 0.8 }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .sheet(isPresented: $selecting) {
            NavigationStack {
                ScrollView {
                    Text(turn.prompt).textSelection(.enabled).padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle("Select text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", systemImage: "checkmark") { selecting = false } } }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

/// SPEC 4.4 action row: copy, share, retry, more; trailing duration.
struct AnswerActionRow: View {
    let turn: AgentTurn
    let isLast: Bool
    let retry: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(spacing: 4) {
            IconAction(copied ? "checkmark" : "doc.on.doc", label: "Copy") {
                UIPasteboard.general.string = turn.answerMarkdown
                withAnimation(.cnxSnap) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation(.cnxSnap) { copied = false }
                }
            }
            .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: copied) { _, new in new }
            ShareLink(item: turn.answerMarkdown) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Share")
            if isLast {
                IconAction("arrow.clockwise", label: "Retry", action: retry)
            }
            Menu {
                Section(turn.promptAt.formatted(.dateTime.weekday(.wide).hour().minute())) {
                    Button("Copy as Markdown", systemImage: "text.document") { UIPasteboard.general.string = turn.answerMarkdown }
                    Button("Fork from here", systemImage: "arrow.triangle.branch") {}
                    Button("Retry", systemImage: "arrow.clockwise", action: retry)
                    Button("Report issue", systemImage: "flag") {}
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .accessibilityLabel("More")
            Spacer()
            if let duration = turn.duration {
                Text(ToolWording().duration(duration)).font(.footnote.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 2)
        .padding(.leading, -8)
    }
}
#endif
