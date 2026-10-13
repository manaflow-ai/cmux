#if os(iOS)
import CnxDesign
import SwiftUI
import UIKit

/// SPEC 12.2: one file's diff with a sticky header, unified or split rows,
/// collapsed context that expands, word highlights, and prev/next/viewed in the bottom toolbar.
public struct DiffFileScreen: View {
    @State private var state: DiffViewerState
    @State private var fileID: String
    @State private var expanded: [String: [ClosedRange<Int>]] = [:]
    @ScaledMetric(relativeTo: .footnote) private var codeSize: CGFloat = 13
    @Environment(\.dismiss) private var dismiss
    @State private var viewportWidth: CGFloat = 400

    init(state: DiffViewerState, fileID: String) {
        _state = State(initialValue: state)
        _fileID = State(initialValue: fileID)
    }

    /// Opens a file directly (a transcript diff header tap).
    public init(changeSet: DiffChangeSet, fileID: String) {
        self.init(state: DiffViewerState(changeSet: changeSet), fileID: fileID)
    }

    private var files: [DiffFile] { state.changeSet.files }
    private var index: Int { files.firstIndex { $0.id == fileID } ?? 0 }
    private var file: DiffFile { files[index] }

    public var body: some View {
        let isViewed = state.viewed.contains(file.id)
        ScrollView(state.wrapLines || state.layout == .split ? .vertical : [.vertical, .horizontal]) {
            if isViewed {
                Label("Viewed. Tap Unmark to show the diff again.", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(20)
                    .transition(.opacity)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(segments) { segment in
                        segmentView(segment)
                    }
                }
                .frame(minWidth: state.wrapLines || state.layout == .split ? nil : contentWidth, alignment: .leading)
                .padding(.bottom, 24)
                .transition(.opacity)
            }
        }
        // Layout changes rebuild the lazy rows (cached row views otherwise keep the old layout).
        .id("\(file.id)|\(state.layout.rawValue)|\(state.wrapLines)")
        .scrollEdgeEffectStyle(.hard, for: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .safeAreaInset(edge: .top, spacing: 0) { stickyHeader(isViewed: isViewed) }
        .navigationTitle(file.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { DiffOptionsMenu(state: state) }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Previous file", systemImage: "chevron.up") { move(-1) }
                    .disabled(index == 0)
                Button("Next file", systemImage: "chevron.down") { move(1) }
                    .disabled(index >= files.count - 1)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button {
                    withAnimation(.cnxSmooth) { state.toggleViewed(file) }
                } label: {
                    Label(isViewed ? "Unmark" : "Mark viewed", systemImage: isViewed ? "checkmark.circle.fill" : "checkmark.circle")
                        .labelStyle(.titleAndIcon)
                        .fixedSize()
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .onChange(of: DemoDirector.shared.serial) { runDemoCommand() }
    }

    private func runDemoCommand() {
        switch DemoDirector.shared.command {
        case .diffSetSplit(let split)?:
            withAnimation(.cnxSmooth) { state.layout = split ? .split : .unified }
        case .diffExpandFirst?:
            if let first = segments.first(where: { if case .collapsed = $0 { return true }; return false }),
               case .collapsed(let range) = first {
                expand(range)
            }
        case .diffMarkViewed?:
            withAnimation(.cnxSmooth) { state.toggleViewed(file) }
        case .navigateBack?:
            dismiss()
        default:
            break
        }
    }

    private func move(_ delta: Int) {
        let next = index + delta
        guard files.indices.contains(next) else { return }
        withAnimation(.cnxSnap) { fileID = files[next].id }
    }

    private func stickyHeader(isViewed: Bool) -> some View {
        HStack(spacing: 10) {
            StatusBadge(status: file.status)
            Text(file.path)
                .font(.footnote.monospaced())
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            DiffCounts(additions: file.additions, deletions: file.deletions)
            ViewedToggle(isViewed: isViewed) { withAnimation(.cnxSmooth) { state.toggleViewed(file) } }
            Menu {
                Button("Copy path", systemImage: "doc.on.doc") { UIPasteboard.general.string = file.path }
            } label: {
                Image(systemName: "ellipsis").frame(width: 32, height: 32)
            }
            .accessibilityLabel("File actions")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Segments

    enum Segment: Identifiable {
        case header(id: Int, text: String)
        case lines(ClosedRange<Int>)
        case collapsed(ClosedRange<Int>)
        case gap(Int)

        var id: String {
            switch self {
            case .header(let id, _): "h\(id)"
            case .lines(let range): "l\(range.lowerBound)"
            case .collapsed(let range): "c\(range.lowerBound)"
            case .gap(let index): "g\(index)"
            }
        }
    }

    private var lines: [DiffLine] {
        guard state.hideWhitespace else { return file.lines }
        return file.lines.filter { $0.kind == .context || !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var segments: [Segment] {
        let lines = lines
        guard !lines.isEmpty else { return [] }
        guard file.hasFullContext else {
            // Parsed diff: hunk lines with gap markers.
            var result: [Segment] = []
            var start = 0
            for (offset, line) in lines.enumerated() where line.isGap {
                if offset > start { result.append(.lines(start...offset - 1)) }
                result.append(.gap(offset))
                start = offset + 1
            }
            if start < lines.count { result.append(.lines(start...lines.count - 1)) }
            return result
        }
        var visible = DiffFile(path: file.path, status: file.status, lines: lines, hasFullContext: true).hunks().map(\.range)
        if visible.isEmpty { visible = [0...lines.count - 1] }
        visible += expanded[file.id] ?? []
        visible.sort { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Int>] = []
        for range in visible {
            if let last = merged.last, range.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        var result: [Segment] = []
        var cursor = 0
        for range in merged {
            if range.lowerBound > cursor {
                result.append(.collapsed(cursor...range.lowerBound - 1))
            }
            if range.lowerBound > 0 || cursor == 0 {
                let hunk = DiffFile(path: file.path, status: file.status, lines: lines, hasFullContext: true).hunks(context: 0)
                    .first { range.contains($0.range.lowerBound) }
                if let hunk, range.lowerBound > 0 || result.isEmpty {
                    result.append(.header(id: range.lowerBound, text: headerText(for: range, lines: lines, fallback: hunk.header)))
                }
            }
            result.append(.lines(range))
            cursor = range.upperBound + 1
        }
        if cursor < lines.count {
            result.append(.collapsed(cursor...lines.count - 1))
        }
        return result
    }

    private func headerText(for range: ClosedRange<Int>, lines: [DiffLine], fallback: String) -> String {
        let slice = lines[range]
        let oldStart = slice.first { $0.oldNumber != nil }?.oldNumber ?? 0
        let newStart = slice.first { $0.newNumber != nil }?.newNumber ?? 0
        let suffix = fallback.components(separatedBy: " @@").dropFirst().joined(separator: " @@")
        return "@@ -\(oldStart),\(slice.count { $0.kind != .added }) +\(newStart),\(slice.count { $0.kind != .removed }) @@\(suffix)"
    }

    @ViewBuilder
    private func segmentView(_ segment: Segment) -> some View {
        switch segment {
        case .header(_, let text):
            hunkHeader(text)
        case .gap:
            hunkHeader("⋯")
        case .collapsed(let range):
            Button {
                expand(range)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.and.down").font(.footnote)
                    Text(range.count > 40 ? "Expand 20 lines" : "Expand \(range.count) lines").font(.footnote)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .frame(height: 32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cnxDiffHunk)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Expand \(range.count) hidden lines"))
        case .lines(let range):
            let lines = lines
            if state.layout == .split {
                ForEach(splitRows(Array(lines[range]))) { row in
                    SplitDiffRow(row: row, codeSize: codeSize, wrap: state.wrapLines, columnWidth: (viewportWidth - 1) / 2)
                }
            } else {
                ForEach(range, id: \.self) { index in
                    UnifiedDiffRow(line: lines[index], codeSize: codeSize, wrap: state.wrapLines)
                        .transition(.opacity)
                }
            }
        }
    }

    private func hunkHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cnxDiffHunk)
    }

    private func expand(_ range: ClosedRange<Int>) {
        let chunk: ClosedRange<Int> = range.count > 40 ? range.lowerBound...range.lowerBound + 19 : range
        withAnimation(.cnxSmooth) {
            expanded[file.id, default: []].append(chunk)
        }
    }

    private var contentWidth: CGFloat {
        let maxChars = file.lines.lazy.map(\.text.count).max() ?? 0
        let charWidth = UIFont.monospacedSystemFont(ofSize: codeSize, weight: .regular).advancement
        return 36 * 2 + 14 + CGFloat(maxChars) * charWidth + 32
    }

    // MARK: Split pairing

    struct SplitRow: Identifiable {
        let id: Int
        let left: DiffLine?
        let right: DiffLine?
    }

    private func splitRows(_ slice: [DiffLine]) -> [SplitRow] {
        var rows: [SplitRow] = []
        var dels: [DiffLine] = []
        var adds: [DiffLine] = []
        func flush() {
            for i in 0..<max(dels.count, adds.count) {
                rows.append(SplitRow(id: rows.count, left: dels[safe: i], right: adds[safe: i]))
            }
            dels = []
            adds = []
        }
        for line in slice {
            switch line.kind {
            case .removed:
                if !adds.isEmpty { flush() }
                dels.append(line)
            case .added: adds.append(line)
            case .context:
                flush()
                rows.append(SplitRow(id: rows.count, left: line, right: line))
            }
        }
        flush()
        return rows
    }
}

extension UIFont {
    var advancement: CGFloat {
        ("M" as NSString).size(withAttributes: [.font: self]).width
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Code text with word-level highlights.
func diffText(_ line: DiffLine) -> AttributedString {
    var text = AttributedString(line.text.isEmpty ? " " : line.text)
    guard !line.changedRanges.isEmpty else { return text }
    let color: Color = line.kind == .added ? .cnxDiffAddWord : .cnxDiffDelWord
    let characters = Array(line.text)
    for range in line.changedRanges where range.upperBound <= characters.count {
        let lower = text.index(text.startIndex, offsetByCharacters: range.lowerBound)
        let upper = text.index(text.startIndex, offsetByCharacters: range.upperBound)
        text[lower..<upper].backgroundColor = color
    }
    return text
}

struct UnifiedDiffRow: View {
    let line: DiffLine
    let codeSize: CGFloat
    let wrap: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter(line.oldNumber)
            gutter(line.newNumber)
            Text(line.marker)
                .frame(width: 14)
                .foregroundStyle(markerColor)
            Text(diffText(line))
                .fixedSize(horizontal: !wrap, vertical: true)
                .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                .padding(.trailing, 16)
        }
        .font(.system(size: codeSize, design: .monospaced))
        .frame(minHeight: codeSize * 1.54, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowColor)
        .contextMenu {
            Button("Copy line", systemImage: "doc.on.doc") { UIPasteboard.general.string = line.text }
            Button("Copy with line number", systemImage: "number") {
                UIPasteboard.general.string = "\(line.newNumber ?? line.oldNumber ?? 0): \(line.text)"
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        switch line.kind {
        case .added: "added line \(line.newNumber ?? 0): \(line.text)"
        case .removed: "removed line \(line.oldNumber ?? 0): \(line.text)"
        case .context: "line \(line.newNumber ?? 0): \(line.text)"
        }
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color(uiColor: .tertiaryLabel))
            .frame(width: 36, alignment: .trailing)
            .padding(.trailing, 4)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 2)
            .background(gutterColor)
    }

    private var markerColor: Color {
        switch line.kind {
        case .added: .cnxDiffAddText
        case .removed: .cnxDiffDelText
        case .context: .secondary
        }
    }

    private var rowColor: Color {
        switch line.kind {
        case .added: .cnxDiffAddRow
        case .removed: .cnxDiffDelRow
        case .context: .clear
        }
    }

    private var gutterColor: Color {
        switch line.kind {
        case .added: .cnxDiffAddGutter
        case .removed: .cnxDiffDelGutter
        case .context: .clear
        }
    }
}

struct SplitDiffRow: View {
    let row: DiffFileScreen.SplitRow
    let codeSize: CGFloat
    let wrap: Bool
    let columnWidth: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            side(row.left, number: row.left?.oldNumber)
            Divider()
            side(row.right, number: row.right?.newNumber)
        }
        .font(.system(size: codeSize, design: .monospaced))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func side(_ line: DiffLine?, number: Int?) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
                .frame(width: 32, alignment: .trailing)
                .padding(.trailing, 6)
                .padding(.top, 2)
            if let line {
                Text(diffText(line))
                    .lineLimit(wrap ? nil : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer()
            }
        }
        .frame(width: columnWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(background(line))
    }

    private func background(_ line: DiffLine?) -> Color {
        guard let line else { return Color.cnxFill }
        switch line.kind {
        case .added: return .cnxDiffAddRow
        case .removed: return .cnxDiffDelRow
        case .context: return .clear
        }
    }
}
#endif
