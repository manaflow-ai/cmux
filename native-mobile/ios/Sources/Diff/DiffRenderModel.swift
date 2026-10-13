import Foundation
import SwiftUI

/// One display line with its attributed text precomputed off the main actor.
struct DiffRenderLine: Sendable {
    var kind: DiffLine.Kind
    var oldNumber: Int?
    var newNumber: Int?
    var text: AttributedString
    /// Display columns (tabs count as 4), for the no-wrap content width.
    var columns: Int
}

struct DiffRowID: Hashable, Sendable {
    var file: Int
    var row: Int
}

/// A row of one file's body, in either layout.
enum DiffRow: Sendable, Identifiable {
    /// A hunk boundary: hidden lines before it (nil when unknown, for the
    /// trailing gap) and the hunk header text. `gap` indexes expansion.
    case hunk(id: DiffRowID, header: String, gap: Int, hidden: Int?)
    case line(id: DiffRowID, DiffRenderLine)
    case split(id: DiffRowID, left: DiffRenderLine?, right: DiffRenderLine?)
    case note(id: DiffRowID, String)

    var id: DiffRowID {
        switch self {
        case .hunk(let id, _, _, _), .line(let id, _), .split(let id, _, _), .note(let id, _): id
        }
    }
}

/// Both layouts for one file, built once per load/expansion.
struct RenderedDiffFile: Sendable {
    var unified: [DiffRow]
    var split: [DiffRow]
    var maxColumns: Int
    /// Digits of the largest line number, for the gutter width.
    var numberDigits: Int
}

/// GitHub-dark-like tints; same alpha in light mode reads well over white.
enum DiffColors {
    static let addRow = Color(.sRGB, red: 46 / 255, green: 160 / 255, blue: 67 / 255, opacity: 0.15)
    static let addWord = Color(.sRGB, red: 46 / 255, green: 160 / 255, blue: 67 / 255, opacity: 0.4)
    static let delRow = Color(.sRGB, red: 248 / 255, green: 81 / 255, blue: 73 / 255, opacity: 0.15)
    static let delWord = Color(.sRGB, red: 248 / 255, green: 81 / 255, blue: 73 / 255, opacity: 0.4)
    static let addGutter = Color(.sRGB, red: 46 / 255, green: 160 / 255, blue: 67 / 255, opacity: 0.22)
    static let delGutter = Color(.sRGB, red: 248 / 255, green: 81 / 255, blue: 73 / 255, opacity: 0.22)
    static let addText = Color(.sRGB, red: 63 / 255, green: 185 / 255, blue: 80 / 255, opacity: 1)
    static let delText = Color(.sRGB, red: 248 / 255, green: 81 / 255, blue: 73 / 255, opacity: 1)

    static func row(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .add: addRow
        case .del: delRow
        case .context, .noNewline: .clear
        }
    }

    static func gutter(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .add: addGutter
        case .del: delGutter
        case .context, .noNewline: .clear
        }
    }
}

/// Builds render rows. Pure; runs on a background task.
enum DiffRenderer {
    /// First new-side line of a hunk and the first line after it. A zero
    /// count means the hunk sits after `start`.
    static func newSpan(_ hunk: DiffHunk) -> (first: Int, after: Int) {
        hunk.newCount > 0 ? (hunk.newStart, hunk.newStart + hunk.newCount) : (hunk.newStart + 1, hunk.newStart + 1)
    }

    static func oldSpan(_ hunk: DiffHunk) -> (first: Int, after: Int) {
        hunk.oldCount > 0 ? (hunk.oldStart, hunk.oldStart + hunk.oldCount) : (hunk.oldStart + 1, hunk.oldStart + 1)
    }

    /// Hidden new-side lines before hunk `index` (the first gap starts at 1).
    static func hiddenBefore(_ hunks: [DiffHunk], index: Int) -> Int {
        let first = newSpan(hunks[index]).first
        let previousAfter = index == 0 ? 1 : newSpan(hunks[index - 1]).after
        return max(0, first - previousAfter)
    }

    /// - Parameters:
    ///   - contents: new-side file lines, when loaded for expansion.
    ///   - expanded: gap indexes (0...hunks.count) the user expanded.
    ///   - canExpand: whether a context loader exists.
    static func render(
        _ file: DiffFile,
        contents: [String]?,
        expanded: Set<Int>,
        canExpand: Bool
    ) -> RenderedDiffFile {
        let language = SyntaxHighlighter.language(forPath: file.path)
        var unified: [DiffRow] = []
        var split: [DiffRow] = []
        var maxColumns = 0
        var maxNumber = 1
        var unifiedCounter = 0
        var splitCounter = 0
        func nextUnified() -> DiffRowID { defer { unifiedCounter += 1 }; return DiffRowID(file: file.index, row: unifiedCounter) }
        func nextSplit() -> DiffRowID { defer { splitCounter += 1 }; return DiffRowID(file: file.index, row: splitCounter) }

        // Open block comments and multi-line strings carry from line to
        // line, separately for each side; a hunk header starts over.
        var oldCarry = SyntaxHighlighter.Carry.none
        var newCarry = SyntaxHighlighter.Carry.none

        func make(_ line: DiffLine, highlights: [Range<Int>]) -> DiffRenderLine {
            // A minified line can be megabytes: cut it and skip highlighting
            // (same limits as the code preview).
            let raw = line.text
            let long = raw.utf8.count > CodeDocument.highlightLineLimit
            let shown = long ? CodeDocument.clipped(raw) : raw
            let columns = shown.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            maxColumns = max(maxColumns, columns + 1)
            maxNumber = max(maxNumber, line.oldNumber ?? 0, line.newNumber ?? 0)
            let text: AttributedString
            if long, line.kind != .noNewline {
                var plain = AttributedString(shown)
                plain.foregroundColor = Theme.ink
                return DiffRenderLine(kind: line.kind, oldNumber: line.oldNumber, newNumber: line.newNumber, text: plain, columns: columns)
            }
            switch line.kind {
            case .noNewline:
                var note = AttributedString(line.text)
                note.foregroundColor = Theme.secondaryInk
                text = note
            case .add:
                text = SyntaxHighlighter.attributed(line.text, language: language, carry: &newCarry, highlights: highlights, highlightColor: DiffColors.addWord)
            case .del:
                text = SyntaxHighlighter.attributed(line.text, language: language, carry: &oldCarry, highlights: highlights, highlightColor: DiffColors.delWord)
            case .context:
                // One row for both sides: colored as the new side reads it.
                text = SyntaxHighlighter.attributed(line.text, language: language, carry: &newCarry)
                oldCarry = newCarry
            }
            return DiffRenderLine(kind: line.kind, oldNumber: line.oldNumber, newNumber: line.newNumber, text: text, columns: columns)
        }

        func appendNote(_ text: String) {
            unified.append(.note(id: nextUnified(), text))
            split.append(.note(id: nextSplit(), text))
        }

        if file.isBinary {
            appendNote(String(localized: "Binary file not shown"))
        }
        if file.hasModeChange, let old = file.oldMode, let new = file.newMode {
            appendNote(String(localized: "File mode changed from \(old) to \(new)"))
        }
        if file.hunks.isEmpty, !file.isBinary, !file.hasModeChange {
            switch file.status {
            case .renamed: appendNote(String(localized: "File renamed without changes"))
            case .copied: appendNote(String(localized: "File copied without changes"))
            case .added, .deleted, .modified: appendNote(String(localized: "Empty file"))
            }
        }

        // Context lines restored from the file for an expanded gap.
        func appendContext(newFrom: Int, newTo: Int, delta: Int) {
            guard let contents, newFrom <= newTo else { return }
            for number in newFrom...newTo where number - 1 < contents.count && number >= 1 {
                let line = make(DiffLine(kind: .context, oldNumber: number + delta, newNumber: number, text: contents[number - 1]), highlights: [])
                unified.append(.line(id: nextUnified(), line))
                split.append(.split(id: nextSplit(), left: line, right: line))
            }
        }

        let expandable = canExpand && file.status != .deleted && !file.isBinary
        for (hunkIndex, hunk) in file.hunks.enumerated() {
            let hidden = hiddenBefore(file.hunks, index: hunkIndex)
            if hidden > 0, expanded.contains(hunkIndex), contents != nil {
                let first = newSpan(hunk).first
                appendContext(newFrom: first - hidden, newTo: first - 1, delta: oldSpan(hunk).first - first)
            } else {
                oldCarry = .none
                newCarry = .none
                unified.append(.hunk(id: nextUnified(), header: hunk.header, gap: hunkIndex, hidden: hidden))
                split.append(.hunk(id: nextSplit(), header: hunk.header, gap: hunkIndex, hidden: hidden))
            }

            let words = DiffLinePairing.wordDiffs(in: hunk.lines)
            let rendered = hunk.lines.enumerated().map { make($0.element, highlights: words[$0.offset] ?? []) }
            for line in rendered { unified.append(.line(id: nextUnified(), line)) }

            // Split: zip runs of deletions with the following additions.
            var i = 0
            while i < rendered.count {
                let line = rendered[i]
                switch line.kind {
                case .context:
                    split.append(.split(id: nextSplit(), left: line, right: line))
                    i += 1
                case .noNewline:
                    split.append(.note(id: nextSplit(), String(line.text.characters)))
                    i += 1
                case .del, .add:
                    var dels: [DiffRenderLine] = []
                    var adds: [DiffRenderLine] = []
                    while i < rendered.count, rendered[i].kind == .del { dels.append(rendered[i]); i += 1 }
                    while i < rendered.count, rendered[i].kind == .add { adds.append(rendered[i]); i += 1 }
                    for k in 0..<max(dels.count, adds.count) {
                        split.append(.split(id: nextSplit(), left: k < dels.count ? dels[k] : nil, right: k < adds.count ? adds[k] : nil))
                    }
                }
            }
        }

        // Trailing gap after the last hunk.
        if expandable, let last = file.hunks.last {
            let trailing = file.hunks.count
            let after = newSpan(last).after
            if expanded.contains(trailing), let contents {
                appendContext(newFrom: after, newTo: contents.count, delta: oldSpan(last).after - after)
            } else if contents.map({ $0.count >= after }) ?? true {
                let hidden = contents.map { $0.count - after + 1 }
                unified.append(.hunk(id: nextUnified(), header: "", gap: trailing, hidden: hidden))
                split.append(.hunk(id: nextSplit(), header: "", gap: trailing, hidden: hidden))
            }
        }

        return RenderedDiffFile(unified: unified, split: split, maxColumns: maxColumns, numberDigits: String(maxNumber).count)
    }
}

/// Splits file text for context expansion (LF or CRLF), keeping blank lines.
extension DiffRenderer {
    static func contentLines(_ text: String) -> [String] {
        UnifiedDiffParser.splitLines(text)
    }
}
