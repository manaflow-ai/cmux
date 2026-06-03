import SwiftUI

struct UnifiedInboxRow: View {
    let item: UnifiedInboxItem
    let dotLeadingPadding: CGFloat
    let dotOffset: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.title)
                    .font(.headline)

                Spacer()

                Text(formatTimestamp(item.sortDate))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(item.preview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.leading, dotLeadingPadding)
        .overlay(alignment: .leading) {
            Circle()
                .fill(Color(uiColor: .systemBlue))
                .frame(width: 8, height: 8)
                .opacity(item.isUnread ? 1 : 0)
                .offset(x: dotOffset)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.row.\(item.workspaceID ?? item.id)")
    }

    func formatTimestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let days = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
            if days < 7 {
                let formatter = DateFormatter()
                formatter.dateFormat = "EEEE"
                return formatter.string(from: date)
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "M/d/yy"
                return formatter.string(from: date)
            }
        }
    }
}
