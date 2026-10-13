import SwiftUI

/// The Mac cut this diff (size cap or too many untracked files): say so,
/// so a partial diff never reads as complete.
struct DiffTruncatedBanner: View {
    var lines: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "scissors")
                .foregroundStyle(Theme.attention)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Diff truncated — showing first \(lines) lines"))
                    .font(.footnote.weight(.semibold))
                Text(String(localized: "The full diff is too large to send. Review the rest on your Mac."))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryInk)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.attention.opacity(0.12), in: .rect(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("diff.truncated")
    }
}

/// GitHub's five-block +/− bar.
struct DiffStatBar: View {
    var additions: Int
    var deletions: Int

    nonisolated static func blocks(additions: Int, deletions: Int) -> (add: Int, del: Int) {
        let total = additions + deletions
        guard total > 0 else { return (0, 0) }
        var add = Int((Double(additions) / Double(total) * 5).rounded())
        if additions > 0 { add = max(add, 1) }
        if deletions > 0 { add = min(add, 4) }
        return (add, 5 - add)
    }

    var body: some View {
        let (add, del) = Self.blocks(additions: additions, deletions: deletions)
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(index < add ? DiffColors.addText : index < add + del ? DiffColors.delText : Theme.tertiaryInk.opacity(0.5))
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityHidden(true)
    }
}

/// `+12 −3` in green and red.
struct DiffCountsLabel: View {
    var additions: Int
    var deletions: Int
    var font: Font = Theme.mono(12, weight: .semibold)

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: "+\(additions)").foregroundStyle(DiffColors.addText)
            Text(verbatim: "\u{2212}\(deletions)").foregroundStyle(DiffColors.delText)
        }
        .font(font)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(additions) additions, \(deletions) deletions"))
    }
}

/// Status letter badge: A, D, M, R, C, or B for a binary file the diff
/// can't show (images show as Before/After and keep M).
struct DiffStatusBadge: View {
    var status: DiffFile.Status
    var isBinary = false

    var letter: String {
        if isBinary, status == .modified { return "B" }
        switch status {
        case .added: return "A"
        case .deleted: return "D"
        case .modified: return "M"
        case .renamed: return "R"
        case .copied: return "C"
        }
    }

    var color: Color {
        switch status {
        case .added: DiffColors.addText
        case .deleted: DiffColors.delText
        case .modified: Theme.attention
        case .renamed, .copied: Theme.secondaryInk
        }
    }

    var body: some View {
        Text(verbatim: letter)
            .font(Theme.mono(11, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .background(color.opacity(0.15), in: .rect(cornerRadius: 4))
            .accessibilityLabel(status.rawValue)
    }
}
