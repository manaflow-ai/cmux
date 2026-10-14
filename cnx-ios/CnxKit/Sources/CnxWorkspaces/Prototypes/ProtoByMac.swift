#if DEBUG && os(iOS)
import CnxDesign
import CnxModel
import SwiftUI

private let theme = CnxTheme.standard

/// Direction B, "Places": Files / Find My / Settings anatomy. Each Mac is an
/// inset-grouped card headed by its presence; rows carry the workspace's own
/// cmux-next color and icon, a branch subtitle and a trailing status label.
/// An offline Mac's card is collapsed to a summary row. No filter control:
/// the Mac grouping is the filter.
struct ProtoByMac: View {
    @State private var expanded: Set<String> = []
    @State private var explaining: Workspace?
    let open: @MainActor (Workspace) -> Void

    private func workspaces(on mac: MacDevice) -> [Workspace] {
        ProtoData.workspaces.filter { $0.macID == mac.id }
            .sorted { (ProtoStatus($0, online: mac.isOnline), $1.lastActivityAt) < (ProtoStatus($1, online: mac.isOnline), $0.lastActivityAt) }
    }

    var body: some View {
        List {
            ForEach(ProtoData.macs) { mac in
                Section {
                    if mac.isOnline || expanded.contains(mac.id) {
                        ForEach(workspaces(on: mac)) { row($0, mac: mac) }
                    } else {
                        collapsedRow(mac)
                    }
                } header: {
                    macHeader(mac)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.colors.bgGrouped.color)
        .navigationTitle("Workspaces")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New Claude Workspace", systemImage: "sparkle") {}
                } label: {
                    Label("New Workspace", systemImage: "square.and.pencil")
                } primaryAction: {}
            }
        }
        .alert(explaining.map { "\(ProtoData.mac($0.macID)?.name ?? "Mac") is offline" } ?? "",
               isPresented: Binding(get: { explaining != nil }, set: { if !$0 { explaining = nil } }),
               presenting: explaining) { _ in
            Button("OK", role: .cancel) {}
        } message: { ws in
            Text("Last seen 2h ago. \u{201C}\(ws.title)\u{201D} opens when the Mac is awake with cmux running.")
        }
    }

    private func macHeader(_ mac: MacDevice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: mac.id == "mbp" ? "laptopcomputer" : "desktopcomputer")
                .font(.subheadline)
                .foregroundStyle(theme.colors.label)
            Text(mac.name)
                .font(theme.type.rowTitle.weight(.semibold))
                .foregroundStyle(theme.colors.label)
            Spacer(minLength: 8)
            StatusDot(mac.isOnline ? .online : .offline, size: 7)
            Text(RelativeStamp().presence(isOnline: mac.isOnline, lastSeenAt: mac.lastSeenAt))
                .font(theme.type.meta)
                .foregroundStyle(theme.colors.label2)
        }
        .textCase(nil)
        .padding(.bottom, 2)
    }

    private func collapsedRow(_ mac: MacDevice) -> some View {
        Button {
            withAnimation(theme.motion.smooth.animation) { _ = expanded.insert(mac.id) }
        } label: {
            HStack {
                Text("\(workspaces(on: mac).count) workspaces")
                    .font(theme.type.rowTitle)
                    .foregroundStyle(theme.colors.label2)
                Spacer()
                Text("Show")
                    .font(theme.type.rowSubtitle)
                    .foregroundStyle(theme.colors.label2)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.colors.label3)
            }
            .frame(minHeight: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(theme.colors.surface.color)
        .accessibilityIdentifier("proto.show.\(mac.id)")
    }

    private func row(_ ws: Workspace, mac: MacDevice) -> some View {
        let st = ProtoStatus(ws, online: mac.isOnline)
        return Button {
            if st == .offline { explaining = ws } else { open(ws) }
        } label: {
            HStack(spacing: 12) {
                WorkspaceGlyph(workspace: ws, dimmed: st == .offline)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ws.title)
                        .font(theme.type.rowTitle)
                        .foregroundStyle(st == .offline ? theme.colors.label3 : theme.colors.label)
                        .lineLimit(1)
                    Text(ws.protoWhere)
                        .font(theme.type.rowSubtitle)
                        .foregroundStyle(st == .offline ? theme.colors.label3 : theme.colors.label2)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                StatusTag(status: st, workspace: ws)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(theme.colors.surface.color)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 42 }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if st != .offline {
                Button("Close", systemImage: "xmark", role: .destructive) {}.tint(nil)
            }
        }
        .contextMenu { protoMenu(ws, status: st, open: open) }
        .accessibilityIdentifier("proto.row.\(ws.id)")
    }
}

/// The workspace's cmux-next color and icon (SF Symbol or emoji) in a 30 pt
/// rounded square; the first letter when it has none.
struct WorkspaceGlyph: View {
    let workspace: Workspace
    var dimmed = false
    var size: CGFloat = 30

    var body: some View {
        // The stored dark value maps to its light/dark pair (SPEC 2.1 team palette).
        let tint = workspace.colorHex.map { hex in
            theme.colors.teamPalette.first { $0.dark.caseInsensitiveCompare(hex) == .orderedSame }?.token.color ?? Color(hex: hex)
        } ?? theme.colors.label2.color
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(tint.opacity(0.18))
            if let icon = workspace.icon, icon.unicodeScalars.first.map({ $0.properties.isEmojiPresentation }) == true {
                Text(icon).font(.system(size: size * 0.5))
            } else if let icon = workspace.icon {
                Image(systemName: icon).font(.system(size: size * 0.47, weight: .medium)).foregroundStyle(tint)
            } else {
                Text(workspace.title.prefix(1).uppercased())
                    .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .opacity(dimmed ? 0.45 : 1)
        .accessibilityHidden(true)
    }
}

/// B's trailing status: a word, never only a color.
struct StatusTag: View {
    let status: ProtoStatus
    let workspace: Workspace

    var body: some View {
        switch status {
        case .needsYou:
            HStack(spacing: 5) {
                Circle().fill(theme.colors.warning.color).frame(width: 7, height: 7)
                Text("Needs you")
            }
            .font(theme.type.meta.weight(.semibold))
            .foregroundStyle(theme.colors.label)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(theme.colors.warning.color.opacity(0.18), in: .capsule)
        case .working:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Working").font(theme.type.meta).foregroundStyle(theme.colors.label2)
            }
        case .done:
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.caption.weight(.semibold))
                Text("Done")
            }
            .font(theme.type.meta)
            .foregroundStyle(theme.colors.label2)
        case .idle, .offline:
            Text(RelativeStamp().string(for: workspace.lastActivityAt))
                .font(theme.type.meta)
                .foregroundStyle(theme.colors.label3)
        }
    }
}
#endif
