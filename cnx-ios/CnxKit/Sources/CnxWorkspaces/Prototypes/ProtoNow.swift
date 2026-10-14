#if DEBUG && os(iOS)
import CnxDesign
import CnxModel
import SwiftUI

private let theme = CnxTheme.standard

/// Direction C, "Now + Everything" (adaptive density): workspaces with live
/// agent state get a rich card at the top (what the agent is doing, where);
/// everything else is a compact one-line list below, with the offline Mac's
/// workspaces last. Mac filter in the toolbar menu, as in A.
struct ProtoNow: View {
    @State private var macFilter: String?
    @State private var explaining: Workspace?
    let open: @MainActor (Workspace) -> Void

    init(filterMacID: String?, open: @escaping @MainActor (Workspace) -> Void) {
        _macFilter = State(initialValue: filterMacID)
        self.open = open
    }

    private func online(_ ws: Workspace) -> Bool { ProtoData.mac(ws.macID)?.isOnline ?? false }
    private func status(_ ws: Workspace) -> ProtoStatus { ProtoStatus(ws, online: online(ws)) }

    private var scoped: [Workspace] {
        ProtoData.workspaces.filter { macFilter == nil || $0.macID == macFilter }
    }

    private var live: [Workspace] {
        scoped.filter { status($0) <= .done }
            .sorted { (status($0), $1.lastActivityAt) < (status($1), $0.lastActivityAt) }
    }

    private var rest: [Workspace] {
        scoped.filter { status($0) > .done }
            .sorted { (online($0) ? 0 : 1, $1.lastActivityAt) < (online($1) ? 0 : 1, $0.lastActivityAt) }
    }

    var body: some View {
        List {
            if !live.isEmpty {
                Section {
                    header("Active")
                    ForEach(live) { card($0) }
                }
            }
            Section {
                header("All Workspaces")
                ForEach(rest) { compact($0) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .listSectionSpacing(8)
        .navigationTitle("Workspaces")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Show", selection: $macFilter) {
                        Text("All Macs").tag(String?.none)
                        ForEach(ProtoData.macs) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Filter", systemImage: macFilter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                }
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
        .animation(theme.motion.smooth.animation, value: macFilter)
    }

    /// A section title as a row that scrolls with the list (not pinned:
    /// pinned plain headers overlap rows under the glass bar).
    private func header(_ title: String) -> some View {
        Text(title)
            .font(theme.type.meta.weight(.semibold))
            .foregroundStyle(theme.colors.label2)
            .accessibilityAddTraits(.isHeader)
            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 2, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private func card(_ ws: Workspace) -> some View {
        let st = status(ws)
        return Button { open(ws) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    WorkspaceGlyph(workspace: ws, size: 26)
                    Text(ws.title)
                        .font(theme.type.rowTitle.weight(.semibold))
                        .foregroundStyle(theme.colors.label)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    StatusTag(status: st, workspace: ws)
                }
                Text(ws.protoAgentTab.map { "\(ws.protoAgentName): \($0.title)" } ?? "")
                    .font(theme.type.rowSubtitle)
                    .foregroundStyle(theme.colors.label)
                    .lineLimit(2)
                Text([ProtoData.mac(ws.macID)?.name, ws.protoWhere, RelativeStamp().string(for: ws.lastActivityAt)]
                    .compactMap(\.self).joined(separator: " · "))
                    .font(theme.type.meta)
                    .foregroundStyle(theme.colors.label2)
                    .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.colors.sheet.color, in: .rect(cornerRadius: theme.metrics.cardRadius, style: .continuous))
            .overlay {
                if st == .needsYou {
                    RoundedRectangle(cornerRadius: theme.metrics.cardRadius, style: .continuous)
                        .strokeBorder(theme.colors.warning.color.opacity(0.6), lineWidth: 1)
                }
            }
            .contentShape(.rect(cornerRadius: theme.metrics.cardRadius))
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .contextMenu { protoMenu(ws, status: st, open: open) }
        .accessibilityIdentifier("proto.card.\(ws.id)")
    }

    private func compact(_ ws: Workspace) -> some View {
        let st = status(ws)
        return Button {
            if st == .offline { explaining = ws } else { open(ws) }
        } label: {
            HStack(spacing: 12) {
                WorkspaceGlyph(workspace: ws, dimmed: st == .offline, size: 26)
                Text(ws.title)
                    .font(theme.type.rowTitle)
                    .foregroundStyle(st == .offline ? theme.colors.label3 : theme.colors.label)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(st == .offline ? "Offline" : (macFilter == nil ? (ProtoData.mac(ws.macID)?.name ?? "") : RelativeStamp().string(for: ws.lastActivityAt)))
                    .font(theme.type.meta)
                    .foregroundStyle(theme.colors.label3)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 2, trailing: 20))
        .listRowBackground(Color.clear)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 38 }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if st != .offline {
                Button("Close", systemImage: "xmark", role: .destructive) {}.tint(nil)
            }
        }
        .contextMenu { protoMenu(ws, status: st, open: open) }
        .accessibilityIdentifier("proto.row.\(ws.id)")
    }
}
#endif
