#if os(iOS)
import CNDesign
import SwiftUI

/// An agent reply: full-width markdown, no bubble.
///
/// While `streaming`, text eases in: a revealed length chases the received
/// length on the display clock, and the newest characters fade from clear to
/// full ink, so each chunk flows in instead of snapping. The chase speed scales
/// with the backlog so the reveal never falls more than ~0.25 s behind.
struct StreamingMarkdown: View {
    var text: String
    var streaming: Bool
    var secondary = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed: Double
    @State private var lastTick: Date?

    init(text: String, streaming: Bool, secondary: Bool = false) {
        self.text = text
        self.streaming = streaming
        self.secondary = secondary
        // A row that appears mid-stream with plenty of text (scrolled back
        // into view) starts caught up; a fresh reply reveals from the start.
        let count = Double(text.count)
        _revealed = State(initialValue: streaming && count < 80 ? 0 : count)
    }

    private var target: Double { Double(text.count) }
    private var catchingUp: Bool { !reduceMotion && revealed < target }

    var body: some View {
        if catchingUp {
            TimelineView(.animation(minimumInterval: nil, paused: !catchingUp)) { context in
                MarkdownContent(text: String(text.prefix(Int(revealed.rounded(.up)))), fade: fade, secondary: secondary)
                    .onChange(of: context.date) { _, now in step(now) }
            }
        } else {
            MarkdownContent(text: text, fade: nil, secondary: secondary)
                .onChange(of: text) { _, new in
                    if !streaming || reduceMotion { revealed = Double(new.count) }
                    lastTick = nil
                }
        }
    }

    /// Tail fade: the last revealed characters ramp from transparent.
    private var fade: TailFade {
        TailFade(fraction: revealed - revealed.rounded(.down), length: 14)
    }

    private func step(_ now: Date) {
        let dt = lastTick.map { min(now.timeIntervalSince($0), 1.0 / 20) } ?? (1.0 / 60)
        lastTick = now
        let backlog = target - revealed
        // At least 90 chars/s; drain any backlog within ~0.25 s.
        let speed = max(90, backlog / 0.25)
        revealed = min(target, revealed + speed * dt)
        if revealed >= target { lastTick = nil }
    }
}

struct TailFade: Hashable {
    /// Fractional progress of the partially revealed character.
    var fraction: Double
    /// Characters over which opacity ramps to 1.
    var length: Int
}

/// Static rendering of markdown blocks.
struct MarkdownContent: View {
    var text: String
    var fade: TailFade?
    var secondary = false

    var body: some View {
        let blocks = MarkdownParser().parse(text)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(block: block, fade: index == blocks.count - 1 ? fade : nil, secondary: secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownBlockView: View {
    var block: MarkdownBlock
    var fade: TailFade?
    var secondary: Bool

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(Inline.render(text, secondary: secondary, fade: fade))
                .lineSpacing(AgentType.bodyLineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(Inline.render(text, secondary: secondary, fade: fade, base: level <= 2 ? .title3.weight(.semibold) : .headline))
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let code, _):
            CodeBlockView(language: language, code: code)
        case .list(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let checked = item.checked {
                            Image(systemName: checked ? "checkmark.square" : "square").foregroundStyle(.cn(\.textSecondary))
                        } else {
                            Text(item.marker)
                                .foregroundStyle(.cn(\.textSecondary))
                                .monospacedDigit()
                                .frame(minWidth: item.marker == "•" ? 10 : 18, alignment: .trailing)
                        }
                        Text(Inline.render(item.text, secondary: secondary, fade: i == items.count - 1 ? fade : nil))
                            .lineSpacing(AgentType.bodyLineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 18)
                }
            }
            .textSelection(.enabled)
        case .table(let header, let rows):
            TableBlockView(header: header, rows: rows)
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(.cn(\.separator)).frame(width: 3)
                Text(Inline.render(text, secondary: true, fade: fade))
                    .lineSpacing(AgentType.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .rule:
            Rectangle().fill(.cn(\.separator)).frame(height: 1).padding(.vertical, 4)
        }
    }
}

/// Inline markdown (bold, italic, code, links) to an AttributedString.
enum Inline {
    static func render(_ source: String, secondary: Bool, fade: TailFade?, base: Font = AgentType.body) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        var s = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        let ink = Color.cn(secondary ? \.textSecondary : \.textPrimary)
        s.foregroundColor = ink
        for run in s.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = base
            if intent.contains(.code) {
                font = .system(.callout, design: .monospaced)
                s[run.range].backgroundColor = Color.cn(\.fillSelection)
            }
            if intent.contains(.stronglyEmphasized) { font = font.weight(.semibold) }
            if intent.contains(.emphasized) { font = font.italic() }
            if intent.contains(.strikethrough) { s[run.range].strikethroughStyle = .single }
            s[run.range].font = font
            if run.link != nil {
                s[run.range].underlineStyle = .single
            }
        }
        if let fade { applyFade(&s, fade: fade, ink: secondary ? \.textSecondary : \.textPrimary) }
        return s
    }

    private static func applyFade(_ s: inout AttributedString, fade: TailFade, ink: KeyPath<CNPalette, UIColor>) {
        let chars = s.characters
        guard !chars.isEmpty else { return }
        var index = chars.endIndex
        let base = UIColor { CNTheme.shared.palette[keyPath: ink].resolvedColor(with: $0) }
        for k in 0..<fade.length {
            guard index > chars.startIndex else { break }
            let prev = chars.index(before: index)
            // k = 0 is the partially revealed character.
            let alpha = min(1, (Double(k) + fade.fraction) / Double(fade.length))
            s[prev..<index].foregroundColor = Color(uiColor: base).opacity(alpha)
            index = prev
        }
    }
}

/// Fenced code: language label, copy, horizontal scroll, SF Mono.
struct CodeBlockView: View {
    var language: String
    var code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.footnote)
                    .foregroundStyle(.cn(\.textSecondary))
                Spacer()
                CopyButton(text: code, label: "Copy")
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(height: 36)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(AgentType.mono)
                    .foregroundStyle(.cn(\.textPrimary))
                    .lineSpacing(3)
                    .fixedSize(horizontal: true, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .background(.cn(\.fillHover), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.cn(\.hairline), lineWidth: 0.5))
    }
}

/// A markdown table in a horizontal scroller.
struct TableBlockView: View {
    var header: [String]
    var rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(Inline.render(cell, secondary: false, fade: nil, base: .subheadline.weight(.semibold)))
                            .padding(.vertical, 8)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(Inline.render(cell, secondary: false, fade: nil, base: .subheadline))
                                .monospacedDigit()
                                .padding(.vertical, 8)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
        }
        .background(.cn(\.fillHover), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.cn(\.hairline), lineWidth: 0.5))
    }
}
#endif
