#if os(iOS)
import SwiftUI
import UIKit

/// Chief's reply while it streams (Live frames v1, `step.delta`): an
/// incoming bubble at the end of the transcript, just above the composer,
/// with the compact "working on" line under it ("Editing src/app.ts · 12s",
/// elapsed time counted here, no per-second frames). Drawn by the Chief
/// screen over the transcript, outside `ConversationStore`: the shared
/// conversation package has no ephemeral row (see ``ChiefSession/shownLive``).
/// It goes away when the reply message arrives or the run ends. Thought
/// text never shows.
struct ChiefLiveBubble: View {
    let session: ChiefSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let live = session.shownLive {
                if let text = Self.replyText(live) {
                    Text(text)
                        .font(.body)
                        .foregroundStyle(.primary)
                        // The newest text: the head is cut, not the tail.
                        .lineLimit(8)
                        .truncationMode(.head)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color(uiColor: .systemGray5), in: .rect(cornerRadius: 18, style: .continuous))
                        .frame(maxWidth: 300, alignment: .leading)
                        .transition(.opacity)
                }
                if let activity = live.activity {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.activityLine(activity, since: live.since, now: context.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.leading, 12)
                    .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .animation(.easeOut(duration: 0.2), value: session.shownLive?.step)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chief.live.bubble")
    }

    static func replyText(_ live: ChiefLive) -> String? {
        let text = live.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return live.truncated ? "…" + text : text
    }

    /// "Editing src/app.ts in sb-3 · 12s".
    static func activityLine(_ line: String, since: Date?, now: Date) -> String {
        guard let since else { return line }
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        let elapsed = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
        return "\(line) · \(elapsed)"
    }
}
#endif
