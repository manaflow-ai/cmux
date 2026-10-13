#if os(iOS)
import CnxDesign
import CnxDiff
import CnxMarkdown
import SwiftUI

/// Opens the diff viewer (`fileID` nil = the file list).
public struct OpenDiffAction: Sendable {
    let handler: @MainActor @Sendable (DiffChangeSet, String?) -> Void

    public init(_ handler: @escaping @MainActor @Sendable (DiffChangeSet, String?) -> Void) {
        self.handler = handler
    }

    @MainActor public func callAsFunction(_ changes: DiffChangeSet, file: String? = nil) {
        handler(changes, file)
    }
}

extension EnvironmentValues {
    @Entry public var openDiff = OpenDiffAction { _, _ in }
}

/// SPEC 6.4 tool row: 32 pt, 15 pt symbol, verb + mono object, chevron that rotates.
struct ToolRowView: View {
    let call: ACPToolCall
    @State private var expanded = false
    private let wording = ToolWording()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.cnxSmooth) { expanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)
            if expanded {
                ToolOutputView(call: call)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        let (verb, object) = wording.verb(call)
        return HStack(spacing: 8) {
            Image(systemName: wording.symbol(call))
                .font(.system(size: 14))
                .foregroundStyle(call.isFailed ? Color.cnxDanger : .secondary)
                .frame(width: 18)
            Group {
                if call.isRunning {
                    WorkingLabel(verb, font: .subheadline)
                } else {
                    Text(verb).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .layoutPriority(1)
            if let object {
                Text(object)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let code = call.exitCode, code != 0 {
                Text("Exit \(code)").font(.footnote).foregroundStyle(Color.cnxDanger)
            }
            Spacer(minLength: 4)
            if call.isRunning {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .frame(minHeight: 32)
        .contentShape(.rect)
    }
}

/// Expanded output: a code card; bash shows `$ command` first; capped at 12 lines.
struct ToolOutputView: View {
    let call: ACPToolCall

    var body: some View {
        let output = call.outputText
        if call.kind == .execute {
            let command = call.command.map { "$ \($0)\n" } ?? ""
            CodeCard(language: "bash", code: command + (output.isEmpty ? "(no output)" : output), title: "Bash", maxHeight: 12 * 19 + 60)
        } else if !output.isEmpty {
            CodeCard(language: call.locations.first.map { ($0.path as NSString).pathExtension } ?? nil, code: output,
                     title: call.locations.first?.path ?? call.title, maxHeight: 12 * 19 + 60)
        } else {
            Text(call.isRunning ? "Loading output…" : "No output.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.leading, 26)
        }
    }
}

/// A run of tool calls as one row; expanded while running (latest visible), collapsed after.
struct ToolGroupView: View {
    let calls: [ACPToolCall]
    let turnRunning: Bool
    @State private var userExpanded: Bool?
    private let wording = ToolWording()

    private var expanded: Bool { userExpanded ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.cnxSmooth) { userExpanded = !expanded }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: calls.contains(where: \.isFailed) ? "exclamationmark.triangle.fill" : "square.stack.3d.down.right")
                        .font(.system(size: 14))
                        .foregroundStyle(calls.contains(where: \.isFailed) ? Color.cnxDanger : .secondary)
                        .frame(width: 18)
                    if calls.contains(where: \.isRunning) {
                        WorkingLabel(wording.summary(calls), font: .subheadline)
                    } else {
                        Text(wording.summary(calls)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if let duration = groupDuration {
                        Text(wording.duration(duration)).font(.footnote.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .frame(minHeight: 32)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(calls) { call in
                        ToolRowView(call: call)
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color(uiColor: .separator)).frame(width: 1).padding(.leading, 8).padding(.vertical, 6)
                }
                .transition(.opacity)
            } else if let live = calls.last(where: \.isRunning) {
                ToolRowView(call: live)
                    .padding(.leading, 12)
                    .transition(.opacity)
            }
        }
    }

    private var groupDuration: TimeInterval? {
        guard !calls.contains(where: \.isRunning),
              let start = calls.compactMap(\.startedAt).min(), let end = calls.compactMap(\.endedAt).max() else { return nil }
        return end.timeIntervalSince(start)
    }
}

/// Collapsed "Thought" row; expands to the reasoning text in label2.
struct ThoughtRow: View {
    let text: String
    let isLive: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.cnxSmooth) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "brain").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 18)
                    if isLive {
                        WorkingLabel("Thinking", font: .subheadline)
                    } else {
                        Text("Thought").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .frame(minHeight: 32)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded || isLive {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 3)
                    .padding(.leading, 26)
                    .transition(.opacity)
            }
        }
    }
}

/// SPEC 6.8 `DiffSnippet`: header "Edited `File.swift` +12 −4 Open", text-colored unified lines, max 12.
struct DiffSnippet: View {
    let call: ACPToolCall
    let changeSet: DiffChangeSet
    @Environment(\.openDiff) private var openDiff
    @State private var showAll = false
    @ScaledMetric(relativeTo: .footnote) private var codeSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(files, id: \.id) { file in
                card(file)
            }
        }
    }

    private var files: [DiffFile] {
        call.diffs.map { DiffFile(path: $0.path, oldText: $0.oldText, newText: $0.newText) }
    }

    private func card(_ file: DiffFile) -> some View {
        let preview = file.unifiedPreview(maxLines: showAll ? 400 : 12)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                openDiff(changeSet, file: file.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: call.isRunning ? "pencil" : (file.status == .added ? "doc.badge.plus" : "pencil"))
                        .font(.system(size: 13))
                    Text(file.status == .added ? "Created" : "Edited").font(.footnote.weight(.medium))
                    Text(file.fileName).font(.footnote.monospaced().weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    DiffCounts(additions: file.additions, deletions: file.deletions)
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Edited \(file.fileName), \(file.additions) additions, \(file.deletions) deletions. Open diff"))
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(preview.lines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 0) {
                            Text(line.kind == .added ? "+" : (line.kind == .removed ? "−" : " "))
                                .frame(width: 14, alignment: .leading)
                            Text(line.text.isEmpty ? " " : line.text)
                        }
                        .foregroundStyle(color(line))
                    }
                }
                .font(.system(size: codeSize, design: .monospaced))
                .lineSpacing(4)
                .fixedSize()
                .padding(.horizontal, 16)
                .padding(.bottom, preview.remaining > 0 ? 4 : 16)
            }
            .scrollIndicators(.hidden)
            if preview.remaining > 0 {
                Button("Show \(preview.remaining) more lines") {
                    withAnimation(.cnxSmooth) { showAll = true }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
                .padding(.top, 4)
            }
        }
        .background(Color.cnxCodeBackground, in: .rect(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color(uiColor: .separator).opacity(0.5), lineWidth: 0.5)
        }
        .contextMenu {
            Button("Open diff", systemImage: "arrow.up.right.square") { openDiff(changeSet, file: file.id) }
            Button("Copy path", systemImage: "doc.on.doc") { UIPasteboard.general.string = file.path }
        }
    }

    private func color(_ line: DiffLine) -> Color {
        switch line.kind {
        case .added: .cnxDiffAddText
        case .removed: .cnxDiffDelText
        case .context: .secondary
        }
    }
}

/// SPEC 6.8 turn summary + acpmux edited-files card: "3 files changed +40 −12", one row per file.
struct EditedFilesCard: View {
    let changeSet: DiffChangeSet
    @Environment(\.openDiff) private var openDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                openDiff(changeSet)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.forwardslash.minus").font(.system(size: 14))
                    Text("\(changeSet.files.count) \(changeSet.files.count == 1 ? "file" : "files") changed").font(.subheadline.weight(.semibold))
                    DiffCounts(additions: changeSet.additions, deletions: changeSet.deletions)
                    Spacer()
                    Text("Review").font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 16)
            ForEach(changeSet.files) { file in
                Button {
                    openDiff(changeSet, file: file.id)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: file.status == .added ? "doc.badge.plus" : "doc.text")
                            .font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
                        Text(file.fileName).font(.subheadline.monospaced()).lineLimit(1)
                        Text(file.directory).font(.footnote).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 4)
                        DiffCounts(additions: file.additions, deletions: file.deletions)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.cnxCard, in: .rect(cornerRadius: 20, style: .continuous))
    }
}
#endif
