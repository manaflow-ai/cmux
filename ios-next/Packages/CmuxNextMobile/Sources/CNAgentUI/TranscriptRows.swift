#if os(iOS)
import CNCore
import CNDesign
import SwiftUI

/// Draws one `ChatRow`. Disclosure state lives in the chat model so it
/// survives lazy-stack recycling.
struct ChatRowView: View {
    let row: ChatRow
    let model: AgentChatModel

    var body: some View {
        switch row {
        case .user(let item, let state):
            UserBubble(item: item, state: state) { model.retry(item.id) }
        case .assistant(let item, _):
            StreamingMarkdown(text: item.text, streaming: item.streaming)
        case .thought(let item):
            ThoughtRow(item: item, open: model.isOpen(item.id)) { toggle(item.id) }
        case .tool(let tool, _):
            ToolRow(tool: tool, open: model.isOpen(tool.id)) { toggle(tool.id) }
        case .toolGroup(let id, let tools, let open):
            DisclosureRow(open: open, action: { toggle(id) }) {
                Image(systemName: "square.stack.3d.up").font(.footnote).foregroundStyle(.cn(\.textTertiary)).frame(width: 20)
                Text(ToolRunCategory.summary(tools)).font(AgentType.row).foregroundStyle(.cn(\.textSecondary)).lineLimit(1)
                if tools.contains(where: { $0.status == .failed }) {
                    Text("· failed").font(AgentType.row).foregroundStyle(.cn(\.textTertiary))
                }
            }
        case .plan(let plan):
            PlanCard(plan: plan)
        case .permission(let p):
            ResolvedPermissionRow(item: p)
        case .notice(let notice):
            NoticeRow(notice: notice)
        case .worked(let id, let label, let open):
            DisclosureRow(open: open, action: { toggle(id) }) {
                Text(label).font(AgentType.row).foregroundStyle(.cn(\.textSecondary)).monospacedDigit()
            }
            .overlay(alignment: .bottom) { Rectangle().fill(.cn(\.hairline)).frame(height: 0.5).opacity(open ? 1 : 0) }
        case .thinking:
            Text("Thinking")
                .font(AgentType.row)
                .shimmer(true)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .accessibilityLabel("Thinking")
        case .working:
            WorkingLine(since: model.turnStartedAt)
        case .editedFiles(let id, let files):
            EditedFilesCard(id: id, files: files, model: model)
        case .turnFooter(let end, let copyText):
            TurnFooter(end: end, copyText: copyText)
        case .unknown(let item):
            NoticeRow(notice: NoticeTranscriptItem(id: item.id, level: .info, text: "Unsupported item: \(item.kind)"))
        }
    }

    private func toggle(_ id: String) {
        Haptics.select()
        withAnimation(CNTheme.shared.motion.move) { model.toggle(id) }
    }
}

// MARK: User

struct UserBubble: View {
    var item: UserTranscriptItem
    var state: LocalSendState
    var retry: () -> Void
    @State private var entered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !item.attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(item.attachments, id: \.self) { a in
                        Label(a.name, systemImage: a.mimeType.hasPrefix("image/") ? "photo" : "doc")
                            .font(.footnote)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(.cn(\.fillHover), in: .capsule)
                            .foregroundStyle(.cn(\.textSecondary))
                    }
                }
            }
            if !item.text.isEmpty {
                Text(item.text)
                    .font(AgentType.body)
                    .lineSpacing(3)
                    .foregroundStyle(.cn(\.textPrimary))
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(.cn(\.fillHover), in: .rect(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.text }
                    }
            }
            switch state {
            case .failed:
                Button(action: retry) {
                    Label("Not sent. Tap to retry", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.cn(\.danger))
                }
                .buttonStyle(.plain)
            case .sending, .sent:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
        // A just-sent bubble rises from the composer and fades in.
        .opacity(state == .sending && !entered ? 0 : 1)
        .offset(y: state == .sending && !entered ? 28 : 0)
        .scaleEffect(state == .sending && !entered ? 0.97 : 1, anchor: .bottomTrailing)
        .onAppear {
            guard state == .sending, !entered else { entered = true; return }
            withAnimation(reduceMotion ? nil : CNTheme.shared.motion.appear) { entered = true }
        }
    }
}

// MARK: Thought

struct ThoughtRow: View {
    var item: ThoughtTranscriptItem
    var open: Bool
    var toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureRow(open: open, action: toggle) {
                Text(label)
                    .font(AgentType.row)
                    .foregroundStyle(.cn(\.textSecondary))
                    .shimmer(item.streaming)
                    .monospacedDigit()
            }
            if open {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 1).fill(.cn(\.separator)).frame(width: 2)
                    StreamingMarkdown(text: item.text, streaming: item.streaming, secondary: true)
                        .font(AgentType.row)
                }
                .padding(.leading, 2)
                .transition(.opacity)
            }
        }
        .clipped()
    }

    private var label: String {
        if item.streaming { return "Thinking" }
        if let ms = item.durationMs { return "Thought for \(AgentFormat.duration(ms: ms))" }
        return "Thought"
    }
}

// MARK: Tools

struct ToolRow: View {
    var tool: ToolCallTranscriptItem
    var open: Bool
    var toggle: () -> Void

    private var command: String? { tool.toolKind == .execute ? AgentFormat.command(tool) : nil }
    private var output: String? { AgentFormat.output(tool) }
    private var diffs: [FileDiff] { tool.diff ?? [] }
    private var running: Bool { tool.status == .running || tool.status == .pending }
    private var openable: Bool { command != nil || output != nil || !diffs.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DisclosureRow(open: open, showsChevron: openable, action: { if openable { toggle() } }) {
                Image(systemName: toolSymbol(tool.toolKind))
                    .font(.footnote)
                    .foregroundStyle(.cn(\.textTertiary))
                    .frame(width: 20)
                label
                    .font(AgentType.row)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .shimmer(running)
                if tool.status == .failed {
                    Text("failed").font(AgentType.row).foregroundStyle(.cn(\.danger).opacity(0.85))
                }
                if !diffs.isEmpty {
                    DiffCountsLabel(counts: diffs.reduce(DiffCounts()) { acc, d in
                        let c = LineDiff.counts(old: d.oldText ?? "", new: d.newText)
                        return DiffCounts(added: acc.added + c.added, removed: acc.removed + c.removed)
                    })
                }
            }
            .accessibilityValue(tool.status.rawValue)
            if open {
                Group {
                    if let command {
                        ShellBlock(command: command, output: output, failed: tool.status == .failed)
                    } else if !diffs.isEmpty {
                        ForEach(diffs, id: \.self) { DiffView(diff: $0) }
                    } else if let output {
                        OutputBlock(text: output)
                    }
                }
                .padding(.leading, 26)
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var label: some View {
        if let command {
            Text("Ran \(Text(command).font(.system(.subheadline, design: .monospaced)).foregroundStyle(.cn(\.textPrimary)))")
                .foregroundStyle(.cn(\.textSecondary))
        } else {
            Text(tool.title.isEmpty ? "Tool call" : tool.title).foregroundStyle(.cn(running ? \.textTertiary : \.textSecondary))
        }
    }
}

struct DiffCountsLabel: View {
    var counts: DiffCounts
    var body: some View {
        HStack(spacing: 4) {
            if counts.added > 0 { Text("+\(counts.added)").foregroundStyle(.cn(\.success)) }
            if counts.removed > 0 { Text("−\(counts.removed)").foregroundStyle(.cn(\.danger)) }
        }
        .font(.footnote.monospacedDigit())
    }
}

/// `$ command` with its output, SF Mono, scrolling both ways.
struct ShellBlock: View {
    var command: String
    var output: String?
    var failed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text("$ \(command)")
                    .font(AgentType.mono)
                    .foregroundStyle(.cn(\.textPrimary))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                CopyButton(text: command)
            }
            if let output {
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    Text(output)
                        .font(AgentType.monoSmall)
                        .lineSpacing(3)
                        .foregroundStyle(.cn(failed ? \.danger : \.textSecondary))
                        .fixedSize()
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.cn(\.fillHover), in: .rect(cornerRadius: 12))
    }
}

struct OutputBlock: View {
    var text: String
    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: false) {
            Text(text)
                .font(AgentType.monoSmall)
                .lineSpacing(3)
                .foregroundStyle(.cn(\.textSecondary))
                .fixedSize()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .background(.cn(\.fillHover), in: .rect(cornerRadius: 12))
    }
}

/// Inline diff: +/- lines on success/danger at low alpha, SF Mono.
struct DiffView: View {
    var diff: FileDiff
    var showsHeader = true

    var body: some View {
        let lines = LineDiff(old: diff.oldText ?? "", new: diff.newText).lines
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                HStack(spacing: 6) {
                    Text(AgentFormat.fileName(diff.path)).font(.footnote.weight(.semibold)).foregroundStyle(.cn(\.textPrimary))
                    Text(AgentFormat.folder(diff.path)).font(.footnote).foregroundStyle(.cn(\.textTertiary)).lineLimit(1).truncationMode(.head)
                    Spacer()
                    if diff.oldText == nil { Text("new").font(.caption).foregroundStyle(.cn(\.textTertiary)) }
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                Rectangle().fill(.cn(\.hairline)).frame(height: 0.5)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in DiffLineView(line: line) }
                }
                .padding(.vertical, 6)
            }
        }
        .background(.cn(\.fillHover), in: .rect(cornerRadius: 12))
        .clipShape(.rect(cornerRadius: 12))
    }
}

struct DiffLineView: View {
    var line: LineDiff.Line

    var body: some View {
        switch line.kind {
        case .gap:
            Text("⋯").font(AgentType.monoSmall).foregroundStyle(.cn(\.textTertiary)).padding(.leading, 12).frame(height: 18)
        default:
            HStack(spacing: 0) {
                Text(line.number.map(String.init) ?? "")
                    .frame(width: 30, alignment: .trailing)
                    .foregroundStyle(.cn(\.textTertiary))
                Text(sign).frame(width: 18).foregroundStyle(signColor)
                Text(line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(.cn(line.kind == .context ? \.textSecondary : \.textPrimary))
                    .fixedSize()
                    .padding(.trailing, 14)
            }
            .font(AgentType.monoSmall)
            .frame(minHeight: 18, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
        }
    }

    private var sign: String { line.kind == .added ? "+" : line.kind == .removed ? "−" : "" }
    private var signColor: Color { line.kind == .added ? .cn(\.success) : .cn(\.danger) }
    private var background: Color {
        switch line.kind {
        case .added: Color.cn(\.success).opacity(0.14)
        case .removed: Color.cn(\.danger).opacity(0.13)
        default: .clear
        }
    }
}

// MARK: Cards

/// "Edited 2 files +12 −4", one row per file that opens to its diff.
struct EditedFilesCard: View {
    var id: String
    var files: [EditedFile]
    let model: AgentChatModel

    var body: some View {
        let totals = files.reduce(DiffCounts()) { DiffCounts(added: $0.added + $1.counts.added, removed: $0.removed + $1.counts.removed) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "plusminus").font(.footnote).foregroundStyle(.cn(\.textSecondary))
                Text(files.count == 1 ? "Edited 1 file" : "Edited \(files.count) files").font(.subheadline.weight(.semibold))
                DiffCountsLabel(counts: totals)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            ForEach(files) { file in
                let key = "\(id)/\(file.path)"
                let open = model.isOpen(key)
                Rectangle().fill(.cn(\.hairline)).frame(height: 0.5)
                Button {
                    Haptics.select()
                    withAnimation(CNTheme.shared.motion.move) { model.toggle(key) }
                } label: {
                    HStack(spacing: 4) {
                        Text(AgentFormat.folder(file.path)).foregroundStyle(.cn(\.textTertiary)).lineLimit(1).truncationMode(.head)
                        Text(AgentFormat.fileName(file.path)).fontWeight(.medium).foregroundStyle(.cn(\.textPrimary)).layoutPriority(1)
                        Spacer(minLength: 8)
                        DiffCountsLabel(counts: file.counts)
                        DisclosureChevron(open: open).padding(.leading, 4)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open {
                    VStack(spacing: 8) {
                        ForEach(file.diffs, id: \.self) { DiffView(diff: $0, showsHeader: false) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity)
                }
            }
        }
        .background(.cn(\.fillHover), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.cn(\.hairline), lineWidth: 0.5))
    }
}

/// The agent's plan as a checklist.
struct PlanCard: View {
    var plan: PlanTranscriptItem

    var body: some View {
        let done = plan.entries.filter { $0.status == .completed }.count
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "list.bullet").font(.footnote).foregroundStyle(.cn(\.textSecondary))
                Text("Plan").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(done) of \(plan.entries.count) done").font(.footnote).foregroundStyle(.cn(\.textTertiary)).monospacedDigit()
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(plan.entries.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: symbol(entry.status))
                            .font(.subheadline)
                            .foregroundStyle(.cn(entry.status == .inProgress ? \.textPrimary : \.textTertiary))
                            .symbolEffect(.pulse, isActive: entry.status == .inProgress)
                        Text(entry.content)
                            .font(.subheadline.weight(entry.status == .inProgress ? .medium : .regular))
                            .foregroundStyle(.cn(entry.status == .completed ? \.textTertiary : \.textPrimary))
                            .strikethrough(entry.status == .completed, color: .cn(\.textTertiary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(entry.status.rawValue)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .background(.cn(\.fillHover), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.cn(\.hairline), lineWidth: 0.5))
    }

    private func symbol(_ s: PlanEntryStatus) -> String {
        switch s {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "circle.dotted.circle"
        default: "circle"
        }
    }
}

struct ResolvedPermissionRow: View {
    var item: PermissionTranscriptItem

    var body: some View {
        let option = item.options.first { $0.id == item.resolved }
        let kind = option?.kind ?? (item.resolved?.hasPrefix("reject") == true ? .rejectOnce : .allowOnce)
        let allowed = kind == .allowOnce || kind == .allowAlways
        HStack(spacing: 8) {
            Image(systemName: allowed ? "checkmark.shield" : "xmark.shield")
                .font(.footnote)
                .foregroundStyle(.cn(\.textTertiary))
                .frame(width: 20)
            Text(verdict(kind, option?.name)).font(AgentType.row).foregroundStyle(.cn(\.textSecondary))
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
    }

    private func verdict(_ kind: PermissionOptionKind, _ name: String?) -> String {
        switch kind {
        case .allowOnce: "Allowed once"
        case .allowAlways: "Always allowed"
        case .rejectOnce, .rejectAlways: "Rejected"
        case .unknown: name ?? "Answered"
        }
    }
}

struct NoticeRow: View {
    var notice: NoticeTranscriptItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(notice.text).foregroundStyle(notice.level == .info ? .cn(\.textTertiary) : color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch notice.level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "exclamationmark.octagon"
        }
    }

    private var color: Color {
        switch notice.level {
        case .info: .cn(\.textTertiary)
        case .warning: .cn(\.warning)
        case .error: .cn(\.danger)
        }
    }
}

/// "Working for 42s", ticking each second from the turn start.
struct WorkingLine: View {
    var since: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(label(context.date))
                .font(AgentType.row)
                .monospacedDigit()
                .shimmer(true)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        }
    }

    private func label(_ now: Date) -> String {
        guard let since else { return "Working" }
        return "Working for \(AgentFormat.duration(ms: max(0, Int(now.timeIntervalSince(since) * 1000))))"
    }
}

/// Under a finished turn: copy the answer; why it stopped when not normal.
struct TurnFooter: View {
    var end: TurnEndTranscriptItem
    var copyText: String

    var body: some View {
        HStack(spacing: 14) {
            if !copyText.isEmpty { CopyButton(text: copyText) }
            switch end.stopReason {
            case "end_turn", "": EmptyView()
            case "cancelled": Text("Stopped").font(.footnote).foregroundStyle(.cn(\.textTertiary))
            case "max_tokens": Text("Hit the output limit").font(.footnote).foregroundStyle(.cn(\.textTertiary))
            case "refusal": Text("The agent declined").font(.footnote).foregroundStyle(.cn(\.textTertiary))
            case "error": Text("Ended with an error").font(.footnote).foregroundStyle(.cn(\.danger))
            default: Text(end.stopReason).font(.footnote).foregroundStyle(.cn(\.textTertiary))
            }
            Spacer()
        }
        .frame(minHeight: 28)
    }
}
#endif
