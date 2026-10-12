import SwiftUI
import UIKit

/// Fixed metrics for the 12pt monospaced diff body.
struct DiffMetrics: Equatable {
    static let fontSize: CGFloat = 12
    static let numberFontSize: CGFloat = 11
    static let charWidth: CGFloat = {
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }()
    static let numberCharWidth: CGFloat = {
        let font = UIFont.monospacedDigitSystemFont(ofSize: numberFontSize, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }()
    static let markerWidth: CGFloat = 16
    static let textPadding: CGFloat = 12

    var digits: Int

    var numberWidth: CGFloat { CGFloat(max(digits, 2)) * Self.numberCharWidth + 10 }

    /// Width of one side's text column for `columns` characters.
    static func textWidth(columns: Int) -> CGFloat { CGFloat(columns) * charWidth + textPadding }
}

/// One unified row, split row, hunk boundary or note. Pure inputs only; the
/// attributed text was built off the main actor.
struct DiffRowView: View {
    let row: DiffRow
    let metrics: DiffMetrics
    let wrap: Bool
    let canExpand: Bool
    let isExpanding: Bool
    let expand: (Int) -> Void

    var body: some View {
        switch row {
        case .line(_, let line):
            DiffUnifiedLineView(line: line, metrics: metrics, wrap: wrap)
        case .split(_, let left, let right):
            HStack(alignment: .top, spacing: 0) {
                DiffSplitHalfView(line: left, side: .old, metrics: metrics, wrap: wrap)
                Rectangle().fill(Theme.separator).frame(width: 1)
                DiffSplitHalfView(line: right, side: .new, metrics: metrics, wrap: wrap)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .hunk(_, let header, let gap, let hidden):
            DiffHunkRowView(header: header, gap: gap, hidden: hidden, canExpand: canExpand, isExpanding: isExpanding, expand: expand)
        case .note(_, let text):
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
    }
}

struct DiffLineNumber: View {
    let number: Int?
    let width: CGFloat

    var body: some View {
        Text(verbatim: number.map(String.init) ?? "")
            .font(.system(size: DiffMetrics.numberFontSize, design: .monospaced))
            .foregroundStyle(Theme.tertiaryInk)
            .frame(width: width, alignment: .trailing)
            .padding(.trailing, 4)
    }
}

private func marker(_ kind: DiffLine.Kind) -> String {
    switch kind {
    case .add: "+"
    case .del: "\u{2212}"
    case .context, .noNewline: " "
    }
}

struct DiffUnifiedLineView: View {
    let line: DiffRenderLine
    let metrics: DiffMetrics
    let wrap: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            DiffLineNumber(number: line.oldNumber, width: metrics.numberWidth)
            DiffLineNumber(number: line.newNumber, width: metrics.numberWidth)
            Text(verbatim: marker(line.kind))
                .font(Theme.mono(DiffMetrics.fontSize))
                .foregroundStyle(line.kind == .add ? DiffColors.addText : line.kind == .del ? DiffColors.delText : Theme.tertiaryInk)
                .frame(width: DiffMetrics.markerWidth)
            DiffLineText(text: line.text, wrap: wrap)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            HStack(spacing: 0) {
                DiffColors.gutter(line.kind).frame(width: (metrics.numberWidth + 4) * 2)
                DiffColors.row(line.kind)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct DiffLineText: View {
    let text: AttributedString
    let wrap: Bool

    var body: some View {
        Text(text)
            .font(Theme.mono(DiffMetrics.fontSize))
            .lineLimit(wrap ? nil : 1)
            .fixedSize(horizontal: !wrap, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, DiffMetrics.textPadding)
    }
}

struct DiffSplitHalfView: View {
    enum Side { case old, new }
    let line: DiffRenderLine?
    let side: Side
    let metrics: DiffMetrics
    let wrap: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let line {
                DiffLineNumber(number: side == .old ? line.oldNumber : line.newNumber, width: metrics.numberWidth)
                Text(verbatim: marker(line.kind))
                    .font(Theme.mono(DiffMetrics.fontSize))
                    .foregroundStyle(line.kind == .add ? DiffColors.addText : line.kind == .del ? DiffColors.delText : Theme.tertiaryInk)
                    .frame(width: DiffMetrics.markerWidth)
                DiffLineText(text: line.text, wrap: wrap)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if let line {
                HStack(spacing: 0) {
                    DiffColors.gutter(line.kind).frame(width: metrics.numberWidth + 4)
                    DiffColors.row(line.kind)
                }
            } else {
                Theme.elevated.opacity(0.6)
            }
        }
    }
}

/// "Expand N hidden lines" plus the hunk header text.
struct DiffHunkRowView: View {
    let header: String
    let gap: Int
    let hidden: Int?
    let canExpand: Bool
    let isExpanding: Bool
    let expand: (Int) -> Void

    private var expandTitle: String? {
        switch hidden {
        case .none: canExpand ? String(localized: "Expand remaining lines") : nil
        case .some(let count) where count > 0:
            canExpand
                ? String(localized: "Expand \(count) hidden lines")
                : String(localized: "\(count) unchanged lines hidden")
        default: nil
        }
    }

    var body: some View {
        if expandTitle != nil || !header.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if let expandTitle {
                    if canExpand {
                        Button { expand(gap) } label: {
                            HStack(spacing: 6) {
                                if isExpanding {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: gap == 0 ? "arrow.up.to.line" : hidden == nil ? "arrow.down.to.line" : "arrow.up.and.down")
                                }
                                Text(expandTitle)
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.ink)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(isExpanding)
                    } else {
                        Label(expandTitle, systemImage: "ellipsis")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }
                if !header.isEmpty {
                    Text(verbatim: header)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.elevated)
        }
    }
}
