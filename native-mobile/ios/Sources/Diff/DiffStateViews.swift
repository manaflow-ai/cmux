import SwiftUI

/// Centered SF Symbol, title, one-line secondary text (REFERENCES.md empty state).
struct DiffEmptyState: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Theme.secondaryInk)
                .padding(.bottom, 4)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Icon, "Couldn't load …", message and a white capsule Retry (Codex list failure).
struct DiffFailureState: View {
    var title: String
    var message: String
    var retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Theme.secondaryInk)
                .padding(.bottom, 4)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
                .lineLimit(4)
            Button(action: retry) {
                Text(String(localized: "Retry"))
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
            }
            .buttonStyle(CapsuleCTAStyle())
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// White capsule CTA in dark mode (ink capsule in light mode).
struct CapsuleCTAStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.background)
            .background(Theme.ink, in: .capsule)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct DiffLoadingState: View {
    var label: String = String(localized: "Loading diff")

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryInk)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// GitHub's five-block +/− bar.
struct DiffStatBar: View {
    var additions: Int
    var deletions: Int

    static func blocks(additions: Int, deletions: Int) -> (add: Int, del: Int) {
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

/// Status letter badge: A, D, M, R, C, or B for binary.
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
