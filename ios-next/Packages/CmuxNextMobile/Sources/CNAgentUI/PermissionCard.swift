#if os(iOS)
import CNCore
import CNDesign
import SwiftUI

/// The pending tool approval, pinned above the composer until answered.
struct PermissionCard: View {
    var pending: PendingPermission
    var answer: (PermissionOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").font(.footnote).foregroundStyle(.cn(\.attention))
                Text("Approval needed").font(.footnote.weight(.semibold)).foregroundStyle(.cn(\.textSecondary))
                Spacer()
                if let tool = pending.tool {
                    Image(systemName: toolSymbol(tool.toolKind)).font(.footnote).foregroundStyle(.cn(\.textTertiary))
                }
            }
            Text(pending.item.title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.cn(\.textPrimary))
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(detail)
                        .font(AgentType.monoSmall)
                        .foregroundStyle(.cn(\.textSecondary))
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                .background(.cn(\.fillHover), in: .rect(cornerRadius: 10))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(spacing: 8) { buttons }
            }
        }
        .padding(14)
        .background(.cn(\.elevated), in: .rect(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.cn(\.hairline), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval needed")
    }

    /// The command or paths the call would touch.
    private var detail: String? {
        guard let tool = pending.tool else { return nil }
        if let command = AgentFormat.command(tool) { return command }
        let paths = tool.locations.map(\.path)
        return paths.isEmpty ? nil : paths.joined(separator: "  ")
    }

    private var ordered: [PermissionOption] {
        let rank: [PermissionOptionKind: Int] = [.allowOnce: 0, .allowAlways: 1, .rejectOnce: 2, .rejectAlways: 3, .unknown: 4]
        return pending.item.options.sorted { (rank[$0.kind] ?? 9) < (rank[$1.kind] ?? 9) }
    }

    @ViewBuilder private var buttons: some View {
        ForEach(ordered) { option in
            Button {
                Haptics.success()
                answer(option)
            } label: {
                Text(title(option))
                    .font(.subheadline.weight(option.kind == .allowOnce ? .semibold : .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .padding(.horizontal, 10)
                    .foregroundStyle(foreground(option.kind))
                    .background(background(option.kind), in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
        }
    }

    private func title(_ o: PermissionOption) -> String {
        switch o.kind {
        case .allowOnce: "Allow once"
        case .allowAlways: "Always"
        case .rejectOnce: "Reject"
        case .rejectAlways: "Never"
        case .unknown: o.name
        }
    }

    private func foreground(_ kind: PermissionOptionKind) -> Color {
        switch kind {
        case .allowOnce: .cn(\.background)
        case .rejectOnce, .rejectAlways: .cn(\.danger)
        default: .cn(\.textPrimary)
        }
    }

    private func background(_ kind: PermissionOptionKind) -> Color {
        kind == .allowOnce ? .cn(\.ink) : .cn(\.fillSelection)
    }
}
#endif
