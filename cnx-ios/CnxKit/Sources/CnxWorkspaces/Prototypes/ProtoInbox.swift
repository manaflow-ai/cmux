#if DEBUG && os(iOS)
import CnxDesign
import CnxModel
import SwiftUI

private let theme = CnxTheme.standard

/// Direction A, "Inbox": Mail/Messages anatomy. Two-line rows (name + time,
/// then a status sentence), attention pinned on top, everything else by
/// recency, an offline Mac folded into one footer section. The Mac filter is a
/// toolbar menu; the title's subtitle says what is filtered or what needs you.
struct ProtoInbox: View {
    @State private var macFilter: String?
    @State private var showOffline = false
    @State private var explaining: Workspace?
    let open: @MainActor (Workspace) -> Void

    init(filterMacID: String?, open: @escaping @MainActor (Workspace) -> Void) {
        _macFilter = State(initialValue: filterMacID)
        self.open = open
    }

    private var scoped: [Workspace] {
        ProtoData.workspaces.filter { macFilter == nil || $0.macID == macFilter }
    }

    private func online(_ ws: Workspace) -> Bool { ProtoData.mac(ws.macID)?.isOnline ?? false }
    private func status(_ ws: Workspace) -> ProtoStatus { ProtoStatus(ws, online: online(ws)) }

    private var attention: [Workspace] {
        scoped.filter { status($0) == .needsYou }.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    private var recent: [Workspace] {
        scoped.filter { online($0) && status($0) != .needsYou }.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    private var offlineMacs: [MacDevice] {
        ProtoData.macs.filter { !$0.isOnline && (macFilter == nil || $0.id == macFilter) }
    }

    private var subtitle: String {
        if let id = macFilter, let mac = ProtoData.mac(id) {
            return "\(mac.name) · " + RelativeStamp().presence(isOnline: mac.isOnline, lastSeenAt: mac.lastSeenAt)
        }
        let waiting = attention.count
        return waiting > 0 ? "\(waiting) need you" : "\(ProtoData.macs.filter(\.isOnline).count) of \(ProtoData.macs.count) Macs online"
    }

    var body: some View {
        List {
            if !attention.isEmpty {
                Section {
                    header("Needs You")
                    ForEach(attention) { row($0) }
                }
            }
            if !recent.isEmpty {
                Section {
                    header("Recent")
                    ForEach(recent) { row($0) }
                }
            }
            ForEach(offlineMacs) { mac in
                Section {
                    offlineHeader(mac)
                        .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 6, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    if showOffline || macFilter != nil {
                        ForEach(scoped.filter { $0.macID == mac.id }.sorted { $0.lastActivityAt > $1.lastActivityAt }) { row($0) }
                    }
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(4)
        .scrollContentBackground(.hidden)
        .navigationTitle("Workspaces")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                filterMenu
                Menu {
                    Section("On Mac Studio") {
                        Button("New Workspace", systemImage: "apple.terminal") {}
                        Button("New Claude Workspace", systemImage: "sparkle") {}
                        Button("New Codex Workspace", systemImage: "sparkle") {}
                    }
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
        .animation(theme.motion.smooth.animation, value: showOffline)
        .animation(theme.motion.smooth.animation, value: macFilter)
    }

    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $macFilter) {
                Label("All Macs", systemImage: "square.stack.3d.up").tag(String?.none)
                ForEach(ProtoData.macs) { mac in
                    Label {
                        Text(mac.name)
                        Text(RelativeStamp().presence(isOnline: mac.isOnline, lastSeenAt: mac.lastSeenAt))
                    } icon: {
                        Image(systemName: mac.id == "mbp" ? "laptopcomputer" : "desktopcomputer")
                    }
                    .tag(Optional(mac.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Filter", systemImage: macFilter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("proto.filter")
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

    private func offlineHeader(_ mac: MacDevice) -> some View {
        Button {
            withAnimation(theme.motion.smooth.animation) { showOffline.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "moon.zzz")
                Text("\(mac.name) · " + RelativeStamp().presence(isOnline: false, lastSeenAt: mac.lastSeenAt))
                Spacer(minLength: 8)
                if macFilter == nil {
                    Text("\(ProtoData.workspaces.filter { $0.macID == mac.id }.count)")
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showOffline ? 90 : 0))
                }
            }
            .font(theme.type.meta.weight(.semibold))
            .foregroundStyle(theme.colors.label2)
            .textCase(nil)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(macFilter != nil)
        .accessibilityIdentifier("proto.offline.\(mac.id)")
    }

    private func row(_ ws: Workspace) -> some View {
        let st = status(ws)
        return Button {
            if st == .offline { explaining = ws } else { open(ws) }
        } label: {
            // The Mac name only when rows from several Macs share a section.
            InboxRow(workspace: ws, status: st, showMac: macFilter == nil && Set(recent.map(\.macID)).count > 1)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 20))
        .listRowBackground(theme.colors.bg.color)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 32 }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if st != .offline {
                Button("Close", systemImage: "xmark", role: .destructive) {}.tint(nil)
                Button("Rename", systemImage: "pencil") {}.tint(.gray)
            }
        }
        .contextMenu {
            protoMenu(ws, status: st, open: open)
        }
        .accessibilityIdentifier("proto.row.\(ws.id)")
    }
}

struct InboxRow: View {
    let workspace: Workspace
    let status: ProtoStatus
    var showMac: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ProtoStatusMark(status: status)
                .frame(width: 32)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(workspace.title)
                        .font(theme.type.rowTitle.weight(.semibold))
                        .foregroundStyle(status == .offline ? theme.colors.label3 : theme.colors.label)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(RelativeStamp().string(for: workspace.lastActivityAt))
                        .font(theme.type.meta)
                        .foregroundStyle(status == .needsYou ? theme.colors.label : theme.colors.label2)
                        .monospacedDigit()
                }
                ProtoStatusLine(workspace: workspace, status: status, showMac: showMac && status >= .idle)
                    .opacity(status == .offline ? 0.6 : 1)
            }
        }
        .contentShape(.rect)
    }
}

/// The row menu shared by the prototypes: Mac and branch in the header,
/// the tabs to jump straight into, then manage actions.
@MainActor @ViewBuilder
func protoMenu(_ ws: Workspace, status: ProtoStatus, open: @escaping @MainActor (Workspace) -> Void) -> some View {
    let mac = ProtoData.mac(ws.macID)
    Section("\(mac?.name ?? "Mac") · \(ws.protoWhere)\(status == .offline ? " · Offline" : "")") {
        if status != .offline {
            ForEach(ws.tabs) { tab in
                Button(tab.title, systemImage: tab.systemImage) { open(ws) }
            }
        }
    }
    if status != .offline {
        Section {
            Button("Rename", systemImage: "pencil") {}
            Button("Close Workspace", systemImage: "xmark", role: .destructive) {}
        }
    }
}
#endif
