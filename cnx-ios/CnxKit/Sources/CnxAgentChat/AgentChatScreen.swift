#if os(iOS)
import CmuxAgentQuestion
import CnxDesign
import CnxDiff
import CnxMarkdown
import SwiftUI
import UIKit

/// SPEC 6: the agent chat. Transcript with follow mode and jump-to-bottom,
/// composer (or the permission action bar), toolbar title menu and actions.
public struct AgentChatScreen: View {
    let store: AgentChatStore
    @State private var text = ""
    @State private var attachments: [AgentAttachment] = []
    @FocusState private var composerFocused: Bool
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var following = true
    @State private var showJump = false
    @State private var diffRoute: DiffRoute?
    @State private var replyInsteadOfPermission = false
    @State private var warningTrigger = 0
    @Environment(\.dismiss) private var dismiss
    private let director = DemoDirector.shared

    public init(store: AgentChatStore) {
        self.store = store
    }

    struct DiffRoute: Identifiable, Hashable {
        let changes: DiffChangeSet
        let fileID: String?
        var id: String { changes.id + (fileID ?? "") }
    }

    public var body: some View {
        transcript
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomStack }
            .background(Color.cnxBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .toolbar(.hidden, for: .tabBar)
            .environment(\.openDiff, OpenDiffAction { changes, file in diffRoute = DiffRoute(changes: changes, fileID: file) })
            .navigationDestination(item: $diffRoute) { route in
                if let file = route.fileID {
                    DiffFileScreen(changeSet: route.changes, fileID: file)
                } else {
                    DiffChangesScreen(changeSet: route.changes)
                }
            }
            .sensoryFeedback(.warning, trigger: warningTrigger)
            .onChange(of: store.pendingPermission?.request.id) { _, new in if new != nil { warningTrigger += 1 } }
            .onChange(of: store.pendingQuestion?.id) { _, new in if new != nil { warningTrigger += 1 } }
            .onChange(of: director.serial) { runDemoCommand() }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
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
                        TurnView(turn: turn, store: store, isLast: turn.id == store.turns.last?.id)
                            .padding(.bottom, 24)
                            .id(turn.id)
                    }
                }
            }
            .padding(.horizontal, 20)
            .scrollTargetLayout()
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY
        } action: { _, distance in
            let away = distance > 80
            if showJump != away { withAnimation(.cnxSnap) { showJump = away } }
            if !away { following = true }
        }
        .onScrollPhaseChange { _, phase, context in
            if phase == .interacting || phase == .decelerating {
                let geometry = context.geometry
                let distance = geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY
                following = distance <= 80
            }
        }
        .onChange(of: store.revision) {
            if following { position.scrollTo(edge: .bottom) }
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

    // MARK: Bottom stack

    private var bottomStack: some View {
        VStack(spacing: 12) {
            if showJump {
                Button {
                    following = true
                    withAnimation(.smooth(duration: 0.35)) { position.scrollTo(edge: .bottom) }
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
            if let permission = store.pendingPermission, !replyInsteadOfPermission {
                PermissionActionBar(request: permission.request) { option in
                    withAnimation(.cnxSmooth) { store.respond(to: permission.request, option: option) }
                } replyInstead: {
                    withAnimation(.cnxSmooth) { replyInsteadOfPermission = true }
                    composerFocused = true
                }
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 28, style: .continuous))
                .padding(.horizontal, 12)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 16)), removal: .opacity))
            } else {
                ChatComposer(store: store, text: $text, attachments: $attachments, focus: $composerFocused, collapsible: !store.turns.isEmpty)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 8)
        .animation(.cnxSmooth, value: store.pendingPermission?.request.id)
        .onChange(of: store.pendingPermission?.request.id) { replyInsteadOfPermission = false }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Menu {
                Button("Rename", systemImage: "pencil") {}
                Button("Open terminal", systemImage: "apple.terminal") {}
                Button("Files", systemImage: "folder") {}
                Button("Changes", systemImage: "plus.forwardslash.minus") { openAllChanges() }
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
                ShareLink(item: transcriptText) { Label("Share transcript", systemImage: "square.and.arrow.up") }
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

    private var transcriptText: String {
        store.turns.map { "> \($0.prompt)\n\n\($0.answerMarkdown)" }.joined(separator: "\n\n---\n\n")
    }

    private func openAllChanges() {
        let files = store.turns.compactMap(\.changeSet).flatMap(\.files)
        guard !files.isEmpty else { return }
        var unique: [String: DiffFile] = [:]
        for file in files { unique[file.id] = file }
        let ordered = files.map(\.id).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.compactMap { unique[$0] }
        diffRoute = DiffRoute(changes: DiffChangeSet(id: "session", title: "Changes", subtitle: store.summary.branch ?? "working tree", files: ordered), fileID: nil)
    }

    // MARK: Demo

    private func runDemoCommand() {
        guard let command = director.command else { return }
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
        default:
            break
        }
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
