import CNMProtocol
import SwiftUI

/// An agent session, styled after ChatGPT/Claude/T3 on iOS: grey user
/// bubbles, full-width assistant markdown, collapsible thinking, tool rows
/// with inline diffs, plans, and approval cards — the Mac agent pane's
/// features in a phone layout.
struct AgentChatView: View {
    let host: HostConnection
    let sessionID: String

    @Environment(ShellState.self) private var shell
    @State private var draft = ""
    @State private var sending = false
    @State private var showTerminal = false
    @State private var error: String?
    @State private var pendingPrompt: String?
    @State private var attachments: [ComposerImage] = []
    @State private var expandedTurns: Set<String> = []
    @State private var viewportHeight: CGFloat = 600
    @FocusState private var focused: Bool

    struct Turn: Identifiable {
        let id: String
        var items: [TranscriptItem]
    }

    /// Splits rows into turns, each starting at a user prompt. A prompt that
    /// is sent but not yet echoed by the Mac shows as its own turn.
    static func turns(_ items: [TranscriptItem], pending: String?) -> [Turn] {
        var turns: [Turn] = []
        for item in items {
            let startsTurn: Bool
            switch item {
            case .userImages: startsTurn = true
            case .user:
                // A prompt with photos already started its turn at the photos.
                if case .userImages = turns.last?.items.last, turns.last?.items.count == 1 { startsTurn = false } else { startsTurn = true }
            default: startsTurn = false
            }
            if startsTurn {
                turns.append(Turn(id: "turn-" + item.id, items: [item]))
            } else if turns.isEmpty {
                turns.append(Turn(id: "turn-start", items: [item]))
            } else {
                turns[turns.count - 1].items.append(item)
            }
        }
        let echoed = turns.last?.items.contains { if case .user(_, let text, _) = $0 { text == pending || (text.isEmpty && pending == String(localized: "Photo")) } else { false } } ?? false
        if let pending, !echoed {
            turns.append(Turn(id: "turn-pending", items: [.user(id: "pending", text: pending, at: .now)]))
        }
        return turns
    }

    enum DisplayEntry: Identifiable {
        case item(TranscriptItem)
        case worked(duration: TimeInterval?, steps: Int, expanded: Bool)
        case edited([FileDiff])

        var id: String {
            switch self {
            case .item(let item): item.id
            case .worked: "worked"
            case .edited: "edited"
            }
        }
    }

    /// A finished turn folds its work (thinking, tool calls, interim text,
    /// answered approvals) into one "Worked for 1m 12s ›" row above the final
    /// answer, as T3 Code and Claude do. A running turn shows everything.
    static func display(_ turn: Turn, expanded: Bool) -> [DisplayEntry] {
        guard let end = turn.items.last, case .turnEnd(_, let duration, _) = end else {
            return turn.items.map(DisplayEntry.item)
        }
        let finalIndex = turn.items.lastIndex { if case .assistant = $0 { true } else { false } }
        var head: [DisplayEntry] = []
        var work: [TranscriptItem] = []
        var tail: [DisplayEntry] = []
        for (index, item) in turn.items.enumerated() {
            switch item {
            case .user, .userImages:
                head.append(.item(item))
            case .plan, .notice, .turnEnd:
                tail.append(.item(item))
            case .permission(let request) where request.resolved == nil:
                tail.append(.item(item))
            default:
                if index == finalIndex { tail.insert(.item(item), at: 0) } else { work.append(item) }
            }
        }
        guard !work.isEmpty else { return turn.items.map(DisplayEntry.item) }
        let steps = work.filter { if case .tool = $0 { true } else { false } }.count
        // The turn's edits, last version per file, as one card under the answer.
        // Each hunk as the agent sent it (Edit diffs are snippets, so
        // successive edits to a file can't be merged into one).
        var edits: [FileDiff] = []
        for item in work {
            guard case .tool(let call) = item, call.status != .failed else { continue }
            edits.append(contentsOf: call.diffs)
        }
        var result = head + [.worked(duration: duration, steps: steps, expanded: expanded)]
            + (expanded ? work.map(DisplayEntry.item) : []) + tail
        if !edits.isEmpty {
            let at = result.lastIndex { if case .item(.turnEnd) = $0 { true } else { false } } ?? result.count
            result.insert(.edited(edits), at: at)
        }
        return result
    }

    static func blocks(text: String, images: [ComposerImage]) -> [JSONValue] {
        var blocks: [JSONValue] = images.map { image in .object(image.block.mapValues(JSONValue.string)) }
        if !text.isEmpty { blocks.append(["type": "text", "text": .string(text)]) }
        return blocks
    }

    static func lastUserID(_ items: [TranscriptItem], pending: String?) -> String? {
        if pending != nil { return "pending" }
        return items.last { if case .user = $0 { true } else { false } }?.id
    }

    private var info: AgentSessionInfo? { host.agents.first { $0.id == sessionID } }
    private var transcript: TranscriptBuilder { host.transcript(for: sessionID) }
    private var working: Bool { info?.state == .working || info?.state == .starting }

    var body: some View {
        let transcript = transcript
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        let turns = Self.turns(transcript.items, pending: pendingPrompt)
                        ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(Self.display(turn, expanded: expandedTurns.contains(turn.id))) { entry in
                                    switch entry {
                                    case .item(let item):
                                        row(item, lastID: transcript.items.last?.id, transcript: transcript)
                                            .id(item.id)
                                            .transition(.opacity)
                                    case .edited(let diffs):
                                        EditedFilesCard(diffs: diffs)
                                    case .worked(let duration, let steps, let expanded):
                                        WorkedRow(duration: duration, steps: steps, expanded: expanded) {
                                            withAnimation(.snappy) {
                                                if expandedTurns.contains(turn.id) { expandedTurns.remove(turn.id) } else { expandedTurns.insert(turn.id) }
                                            }
                                        }
                                    }
                                }
                                if index == turns.count - 1, working || pendingPrompt != nil,
                                   !(turn.items.last.map(isStreamingRow) ?? false)
                                {
                                    WorkingIndicator(label: workingLabel(transcript))
                                        .id("working")
                                        .transition(.opacity)
                                }
                            }
                            // The latest turn fills the screen so its prompt can sit at
                            // the top while the reply grows under it (ChatGPT, T3).
                            .frame(minHeight: index == turns.count - 1 ? max(0, viewportHeight - 24) : 0, alignment: .top)
                            .id(turn.id)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: Self.lastUserID(transcript.items, pending: pendingPrompt)) { _, id in
                    guard let id else { return }
                    // Measured from ChatGPT: the sent prompt springs to the top in ~430 ms.
                    withAnimation(.spring(response: 0.35, dampingFraction: 1.0)) { proxy.scrollTo(id, anchor: .top) }
                }
                .onChange(of: transcript.items.filter { if case .user = $0 { true } else { false } }.count) { _, _ in
                    pendingPrompt = nil
                }
                .overlay {
                    if transcript.items.isEmpty, !working {
                        AgentEmptyState(info: info, hostName: host.name)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 6) {
                        if let error {
                            Text(error).font(.footnote).foregroundStyle(CmuxTheme.danger)
                                .padding(.horizontal, 16)
                        }
                        AgentComposer(
                            text: $draft,
                            attachments: $attachments,
                            focused: $focused,
                            placeholder: "Ask \(HarnessStyle.of(info?.harness ?? "").name)",
                            working: working,
                            // An ended agent restarts (and resumes its session) on the next prompt.
                            canSend: info?.archived != true,
                            modes: info?.modes ?? [],
                            currentMode: info?.currentMode,
                            models: info?.models ?? [],
                            currentModel: info?.currentModel,
                            commands: transcript.commands,
                            onMode: { host.setMode(sessionID, $0) },
                            onModel: { host.setModel(sessionID, $0) },
                            send: send,
                            stop: { host.cancel(sessionID) }
                        )
                    }
                }
            }
            .navigationTitle(info?.title ?? "Agent")
            .navigationSubtitle("\(((info?.cwd ?? "") as NSString).lastPathComponent) · \(host.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { DrawerButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showTerminal = true
                    } label: {
                        Image(systemName: "apple.terminal")
                    }
                    .accessibilityLabel("Terminal in this folder")
                    .accessibilityIdentifier("agent.terminal")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showTerminal = true
                        } label: {
                            Label("Terminal in this folder", systemImage: "apple.terminal")
                        }
                        Button {
                            shell.go(.newAgent)
                        } label: {
                            Label("New agent chat", systemImage: "square.and.pencil")
                        }
                        Divider()
                        Button(role: .destructive) {
                            host.archiveAgent(sessionID)
                            shell.go(.home)
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityIdentifier("agent.menu")
                }
            }
            .fullScreenCover(isPresented: $showTerminal) {
                TerminalLauncher(host: host, cwd: info?.cwd)
            }
        }
        .task { await host.attachAgent(sessionID) }
    }

    private func isStreamingRow(_ item: TranscriptItem) -> Bool {
        switch item {
        case .assistant, .thought: true
        case .tool(let call): call.status == .inProgress || call.status == .pending
        case .permission(let request): request.resolved == nil
        default: false
        }
    }

    private func workingLabel(_ transcript: TranscriptBuilder) -> String {
        if info?.state == .starting { return String(localized: "Starting \(HarnessStyle.of(info?.harness ?? "").name)…") }
        return String(localized: "Working…")
    }

    @ViewBuilder
    private func row(_ item: TranscriptItem, lastID: String?, transcript: TranscriptBuilder) -> some View {
        switch item {
        case .user(_, let text, _):
            if !text.isEmpty { UserBubble(text: text) }
        case .userImages(_, let images):
            UserImagesRow(images: images)
        case .assistant(let id, let text):
            MarkdownView(text: text, streaming: working && id == lastID)
                .textSelection(.enabled)
                .contextMenu {
                    Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
        case .thought(_, let text, let streaming):
            ThoughtRow(text: text, streaming: streaming && working)
        case .tool(let call):
            ToolCallRow(call: call)
        case .plan(_, let entries):
            PlanCard(entries: entries)
        case .permission(let request):
            PermissionCard(request: request) { option in
                host.answerPermission(sessionID, request: request.id, option: option)
            }
        case .notice(_, let text, let isError):
            Label(text, systemImage: isError ? "exclamationmark.triangle" : "info.circle")
                .font(.footnote)
                .foregroundStyle(isError ? CmuxTheme.danger : .secondary)
        case .turnEnd(_, let duration, let reason):
            TurnEndRow(duration: duration, reason: reason, lastText: lastAssistantText(before: item.id, in: transcript.items))
        }
    }

    private func lastAssistantText(before id: String, in items: [TranscriptItem]) -> String? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        for item in items[..<index].reversed() {
            if case .assistant(_, let text) = item { return text }
            if case .user = item { return nil }
        }
        return nil
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let blocks = Self.blocks(text: text, images: attachments)
        draft = ""
        attachments = []
        error = nil
        pendingPrompt = text.isEmpty ? String(localized: "Photo") : text
        Task {
            do {
                try await host.prompt(sessionID, blocks: blocks)
            } catch {
                self.error = error.localizedDescription
                pendingPrompt = nil
                draft = text
            }
        }
    }
}

/// "2 files changed +14 −3 ›" under a turn's answer; opens the full diffs.
struct EditedFilesCard: View {
    let diffs: [FileDiff]
    @State private var reviewing = false

    private struct FileTotal { let path: String; var added: Int; var removed: Int }

    /// Hunks summed per file, in first-edit order.
    private var perFile: [FileTotal] {
        var totals: [FileTotal] = []
        for diff in diffs {
            if let index = totals.firstIndex(where: { $0.path == diff.path }) {
                totals[index].added += diff.added
                totals[index].removed += diff.removed
            } else {
                totals.append(FileTotal(path: diff.path, added: diff.added, removed: diff.removed))
            }
        }
        return totals
    }

    private var fileCount: Int { perFile.count }

    var body: some View {
        Button { reviewing = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.badge.ellipsis").font(.system(size: 13))
                    Text(fileCount == 1 ? String(localized: "1 file changed") : String(localized: "\(fileCount) files changed"))
                        .font(.system(size: 15, weight: .semibold))
                    Text("+\(diffs.reduce(0) { $0 + $1.added })").foregroundStyle(CmuxTheme.success)
                    Text("−\(diffs.reduce(0) { $0 + $1.removed })").foregroundStyle(CmuxTheme.danger)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                ForEach(perFile.prefix(4), id: \.path) { file in
                    HStack(spacing: 6) {
                        Text((file.path as NSString).lastPathComponent).font(.system(size: 13, design: .monospaced)).lineLimit(1)
                        Spacer()
                        Text("+\(file.added)").foregroundStyle(CmuxTheme.success)
                        Text("−\(file.removed)").foregroundStyle(CmuxTheme.danger)
                    }
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(CmuxTheme.chrome, in: .rect(cornerRadius: 14, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("agent.edited")
        .sheet(isPresented: $reviewing) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(Array(diffs.enumerated()), id: \.offset) { DiffView(diff: $0.element) }
                    }
                    .padding(16)
                }
                .navigationTitle(fileCount == 1 ? String(localized: "1 file changed") : String(localized: "\(fileCount) files changed"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { reviewing = false }.accessibilityIdentifier("edited.done") }
                }
            }
            .presentationDetents([.large])
        }
    }
}

/// "Worked for 1m 12s · 6 steps ›": the folded work of a finished turn.
struct WorkedRow: View {
    let duration: TimeInterval?
    let steps: Int
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 15, weight: .medium))
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("agent.worked")
    }

    private var label: String {
        var parts: [String] = []
        if let duration, duration >= 1 { parts.append(String(localized: "Worked for \(TurnEndRow.format(duration))")) }
        else { parts.append(String(localized: "Worked")) }
        if steps > 0 { parts.append(steps == 1 ? String(localized: "1 step") : String(localized: "\(steps) steps")) }
        return parts.joined(separator: " · ")
    }
}

struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(.system(size: 17))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemFill), in: .rect(cornerRadius: 20, style: .continuous))
                .textSelection(.enabled)
        }
        .padding(.top, 6)
    }
}

/// "Thinking" collapsed to one shimmering line; tap to read it.
struct ThoughtRow: View {
    let text: String
    let streaming: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(streaming ? "Thinking" : "Thought")
                        .font(.system(size: 15, weight: .medium))
                        .modifier(Shimmer(active: streaming))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(Color(.separator)).frame(width: 2) }
                    .transition(.opacity)
            }
        }
    }
}

struct Shimmer: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    GeometryReader { geometry in
                        LinearGradient(colors: [.clear, Color(.systemBackground).opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geometry.size.width * 0.6)
                            .offset(x: phase * geometry.size.width * 1.6)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard active else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

struct ToolCallRow: View {
    let call: ToolCall
    @State private var expanded = false

    private var hasDetail: Bool { !call.diffs.isEmpty || !call.text.isEmpty || call.command != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                guard hasDetail else { return }
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    statusIcon
                    Text(call.title)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 1)
                        .multilineTextAlignment(.leading)
                    if let diff = call.diffs.first, call.diffs.count == 1 {
                        Text("+\(diff.added)").foregroundStyle(CmuxTheme.success).font(.system(size: 13, weight: .medium, design: .monospaced))
                        Text("−\(diff.removed)").foregroundStyle(CmuxTheme.danger).font(.system(size: 13, weight: .medium, design: .monospaced))
                    }
                    Spacer(minLength: 0)
                    if hasDetail {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let command = call.command {
                        Text("$ " + command)
                            .font(.system(size: 13, design: .monospaced))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(CmuxTheme.terminalBackground, in: .rect(cornerRadius: 10, style: .continuous))
                    }
                    ForEach(call.diffs, id: \.self) { diff in DiffView(diff: diff) }
                    if !call.text.isEmpty, call.diffs.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(String(call.text.prefix(4000)))
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                        .frame(maxHeight: 260)
                        .background(CmuxTheme.chrome, in: .rect(cornerRadius: 10, style: .continuous))
                    }
                }
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch call.status {
        case .pending, .inProgress:
            ProgressView().controlSize(.mini).frame(width: 18)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(CmuxTheme.danger).frame(width: 18)
        case .completed:
            Image(systemName: call.symbol).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
        }
    }
}

struct DiffView: View {
    let diff: FileDiff
    @State private var cardWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc").font(.system(size: 11))
                Text((diff.path as NSString).lastPathComponent).font(.system(size: 12, weight: .semibold))
                Text((diff.path as NSString).deletingLastPathComponent).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                Spacer()
                Text("+\(diff.added)").foregroundStyle(CmuxTheme.success)
                Text("−\(diff.removed)").foregroundStyle(CmuxTheme.danger)
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.lines.prefix(400).enumerated()), id: \.offset) { _, line in
                        Text("\(String(line.1)) \(line.0)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(line.1 == " " ? Color.secondary : Color.primary)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(line.1 == "+" ? CmuxTheme.success.opacity(0.14) : line.1 == "-" ? CmuxTheme.danger.opacity(0.14) : .clear)
                    }
                }
                .padding(.vertical, 4)
                // Row tints span the card even when every line is short.
                .frame(minWidth: cardWidth, alignment: .leading)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cardWidth = $0 }
            .frame(maxHeight: 320)
        }
        .background(CmuxTheme.chrome, in: .rect(cornerRadius: 10, style: .continuous))
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
    }
}

struct PlanCard: View {
    let entries: [PlanEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Plan").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: entry.status == "completed" ? "checkmark.circle.fill" : entry.status == "in_progress" ? "circle.dotted.circle" : "circle")
                        .foregroundStyle(entry.status == "completed" ? CmuxTheme.success : entry.status == "in_progress" ? CmuxTheme.highlight : .secondary)
                        .font(.system(size: 14))
                    Text(entry.content)
                        .font(.system(size: 15))
                        .strikethrough(entry.status == "completed", color: .secondary)
                        .foregroundStyle(entry.status == "completed" ? .secondary : .primary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CmuxTheme.chrome, in: .rect(cornerRadius: 14, style: .continuous))
    }
}

struct PermissionCard: View {
    let request: PermissionRequest
    let answer: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text(request.title).font(.system(size: 15, weight: .semibold)).lineLimit(3)
            }
            if let body = request.body, !body.isEmpty {
                ScrollView {
                    MarkdownView(text: body)
                        .font(.system(size: 15))
                        .padding(12)
                }
                .frame(maxHeight: request.resolved == nil ? 320 : 120)
                .background(Color(.systemBackground).opacity(0.7), in: .rect(cornerRadius: 12, style: .continuous))
            }
            if let detail = request.detail {
                Text(detail)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CmuxTheme.terminalBackground, in: .rect(cornerRadius: 10, style: .continuous))
            }
            if let resolved = request.resolved {
                let name = request.options.first { $0.id == resolved }?.name ?? String(localized: "Cancelled")
                Label(name, systemImage: resolved == nil ? "xmark" : "checkmark")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                let primary = request.options.filter { $0.kind == "reject_once" || $0.kind == "allow_once" }
                let secondary = request.options.filter { !primary.contains($0) }
                HStack(spacing: 8) {
                    ForEach(primary.sorted { order($0) < order($1) }) { option in optionButton(option, filled: option.kind == "allow_once") }
                }
                ForEach(secondary.sorted { order($0) < order($1) }) { option in optionButton(option, filled: false) }
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.orange.opacity(request.resolved == nil ? 0.45 : 0.15), lineWidth: 1))
    }

    private func optionButton(_ option: PermissionRequest.Option, filled: Bool) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            answer(option.id)
        } label: {
            Text(option.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 42)
                .padding(.horizontal, 8)
                .foregroundStyle(filled ? Color(.systemBackground) : .primary)
                .background(filled ? Color.primary : Color(.secondarySystemFill), in: .rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityIdentifier("permission.\(option.kind)")
    }

    private func order(_ option: PermissionRequest.Option) -> Int {
        switch option.kind {
        case "reject_once": 0
        case "allow_once": 1
        case "allow_always": 2
        default: 3
        }
    }
}

struct TurnEndRow: View {
    let duration: TimeInterval?
    let reason: String
    let lastText: String?
    @State private var copied = false

    var body: some View {
        HStack(spacing: 14) {
            if let lastText {
                Button {
                    UIPasteboard.general.string = lastText
                    withAnimation(.snappy) { copied = true }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy reply")
            }
            if reason == "cancelled" {
                Text("Stopped").font(.footnote)
            }
            Spacer()
        }
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        return "\(total / 60)m \(total % 60)s"
    }
}

struct WorkingIndicator: View {
    let label: String
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.primary)
                .frame(width: 9, height: 9)
                .scaleEffect(pulse ? 1 : 0.6)
                .opacity(pulse ? 1 : 0.4)
            Text(label).font(.system(size: 15)).foregroundStyle(.secondary).modifier(Shimmer(active: true))
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { pulse = true } }
    }
}

struct AgentEmptyState: View {
    let info: AgentSessionInfo?
    let hostName: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: HarnessStyle.of(info?.harness ?? "").symbol)
                .font(.system(size: 30))
                .foregroundStyle(HarnessStyle.of(info?.harness ?? "").tint)
            Text(HarnessStyle.of(info?.harness ?? "").name).font(.title3.weight(.semibold))
            Text("\(((info?.cwd ?? "") as NSString).abbreviatingWithTildeInPath) on \(hostName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 80)
    }
}
