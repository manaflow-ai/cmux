#if os(iOS)
import CnxDesign
import CnxModel
import SwiftUI

private let theme = CnxTheme.standard

/// How the Workspaces list orders rows inside each Mac.
public enum WorkspaceSort: String, CaseIterable, Identifiable, Sendable {
    case recent, name
    public var id: String { rawValue }
    var title: LocalizedStringKey { self == .recent ? "Recent" : "Name" }

    func ordered(_ items: [Workspace]) -> [Workspace] {
        switch self {
        case .recent: items.sorted { $0.lastActivityAt > $1.lastActivityAt }
        case .name: items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }
}

/// SPEC 11.1: the Workspaces tab's content. One plain section per Mac
/// (presence dot, name, "Online" / "Last seen"), workspace rows with icon,
/// branch, tab count, relative time and status. Rows push `Workspace`
/// values; the enclosing NavigationStack maps them to `WorkspaceScreen`.
/// Loading, failure and the empty states come first.
public struct WorkspacesList: View {
    let store: AppStore
    @AppStorage("cnx.workspaces.sort") private var sort: WorkspaceSort = .recent
    @AppStorage("cnx.workspaces.showOffline") private var showsOffline = true
    @State private var isRetrying = false
    @State private var creating = false

    public init(store: AppStore) {
        self.store = store
    }

    public var body: some View {
        content
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("New workspace", systemImage: "square.and.pencil") { creating = true }
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(WorkspaceSort.allCases) { Text($0.title).tag($0) }
                        }
                        Toggle("Show Offline Macs", systemImage: "moon.zzz", isOn: $showsOffline)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
            .sheet(isPresented: $creating) {
                NewWorkspaceSheet(store: store)
            }
    }

    @ViewBuilder private var content: some View {
        let macs = store.activeTeam?.macs ?? []
        switch store.teamDataState {
        case .loading:
            ScrollView { SkeletonList(rows: 6, leadingSquare: 36).padding(.top, 8) }
                .scrollDisabled(true)
        case .failed:
            EmptyState(
                symbol: "cloud",
                title: "Couldn't load workspaces",
                message: "Check your connection and try again.",
                primaryTitle: "Retry",
                isPrimaryLoading: isRetrying,
                primary: retry
            )
        case .loaded:
            if macs.isEmpty {
                EmptyState(
                    symbol: "desktopcomputer",
                    title: "Connect your Mac",
                    message: "Open cmux on your Mac and choose Pair iPhone to get a code.",
                    primaryTitle: "Scan QR code", primary: {},
                    secondaryTitle: "Enter code manually", secondary: {}
                )
            } else if !macs.contains(where: \.isOnline) && !showsOffline {
                EmptyState(
                    symbol: "moon.zzz",
                    title: "Your Macs are asleep",
                    message: "Wake a Mac or open cmux on it to see its workspaces.",
                    secondaryTitle: "Show offline Macs", secondary: { showsOffline = true }
                )
            } else {
                list(macs: macs.filter { showsOffline || $0.isOnline })
            }
        }
    }

    private func list(macs: [MacDevice]) -> some View {
        let stamp = RelativeStamp()
        // Online Macs first, keeping the team's order inside each group.
        let ordered = macs.filter(\.isOnline) + macs.filter { !$0.isOnline }
        return List {
            ForEach(ordered) { mac in
                let items = sort.ordered(store.workspaces.filter { $0.macID == mac.id })
                Section {
                    if items.isEmpty {
                        Text(mac.isOnline ? "No workspaces" : "Offline")
                            .font(theme.type.rowSubtitle)
                            .foregroundStyle(theme.colors.label2)
                            .listRowBackground(theme.colors.bg.color)
                    }
                    ForEach(items) { ws in
                        NavigationLink(value: ws) {
                            WorkspaceRow(workspace: ws, stamp: stamp.string(for: ws.lastActivityAt), dimmed: !mac.isOnline)
                        }
                        .listRowBackground(theme.colors.bg.color)
                        .listRowInsets(EdgeInsets(top: 0, leading: theme.metrics.sideMargin, bottom: 0, trailing: 16))
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 48 }
                    }
                } header: {
                    MacSectionHeader(mac: mac, presence: stamp.presence(isOnline: mac.isOnline, lastSeenAt: mac.lastSeenAt))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {}
        .animation(theme.motion.smooth.animation, value: sort)
        .animation(theme.motion.smooth.animation, value: showsOffline)
    }

    private func retry() {
        isRetrying = true
        Task {
            await Task.yield()
            store.teamDataState = .loaded
            isRetrying = false
        }
    }
}

/// Section header: 44 pt, presence dot, Mac name, "Online" / "Last seen …",
/// trailing More menu.
struct MacSectionHeader: View {
    let mac: MacDevice
    let presence: String

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(mac.isOnline ? .online : .offline, size: 7)
            Text(mac.name)
                .font(theme.type.rowSubtitle.weight(.semibold))
                .foregroundStyle(theme.colors.label)
            Text(presence)
                .font(theme.type.meta)
                .foregroundStyle(theme.colors.label2)
            Spacer(minLength: 0)
            Menu {
                Button("Pair Details", systemImage: "info.circle") {}
                Button("Reconnect", systemImage: "arrow.clockwise") {}
                Button("Unpair", systemImage: "minus.circle", role: .destructive) {}
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.colors.label2)
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .accessibilityLabel("\(mac.name) options")
        }
        .textCase(nil)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

/// SPEC 11.1 workspace row (64 pt).
struct WorkspaceRow: View {
    let workspace: Workspace
    let stamp: String
    var dimmed = false

    var body: some View {
        HStack(spacing: 12) {
            WorkspaceIcon(workspace: workspace)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if workspace.hasUnread {
                        Circle().fill(theme.colors.label.color).frame(width: 8, height: 8)
                            .accessibilityLabel("Unread")
                    }
                    Text(workspace.title).font(theme.type.rowTitle.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(stamp).font(theme.type.meta).foregroundStyle(theme.colors.label2)
                }
                HStack(spacing: 6) {
                    subtitle
                        .font(theme.type.meta)
                        .foregroundStyle(theme.colors.label2)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    status
                }
            }
        }
        .frame(minHeight: 64)
        .opacity(dimmed ? 0.55 : 1)
        .contentShape(.rect)
    }

    private var subtitle: Text {
        let tabs = workspace.tabs.count == 1 ? "1 tab" : "\(workspace.tabs.count) tabs"
        if let branch = workspace.branch {
            return Text("\(Text(branch).monospaced()) · \(tabs)")
        }
        return Text(tabs)
    }

    @ViewBuilder private var status: some View {
        if workspace.needsAttention {
            HStack(spacing: 5) {
                Circle().fill(theme.colors.warning.color).frame(width: 6, height: 6)
                Text("Needs you").font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(theme.colors.fill.color, in: .capsule)
        } else if workspace.isWorking {
            ProgressView().controlSize(.mini)
                .frame(width: 12, height: 12)
                .accessibilityLabel("Working")
        }
    }
}

/// 36 pt rounded square with the workspace's icon in its color.
struct WorkspaceIcon: View {
    let workspace: Workspace

    var body: some View {
        let tint = workspace.colorHex.map { theme.colors.team($0).color } ?? theme.colors.label2.color
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(0.18))
            if let icon = workspace.icon, icon.unicodeScalars.first?.properties.isEmojiPresentation == true {
                Text(icon).font(.system(size: 18))
            } else {
                Image(systemName: workspace.icon ?? "folder")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }
}

/// New workspace (SPEC 11.1): Mac, directory, first tab.
struct NewWorkspaceSheet: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var macID = ""
    @State private var directory = "~/Development/"
    @State private var firstTab = "claude"

    var body: some View {
        NavigationStack {
            Form {
                Picker("Mac", selection: $macID) {
                    ForEach(store.activeTeam?.macs.filter(\.isOnline) ?? []) { Text($0.name).tag($0.id) }
                }
                TextField("Directory", text: $directory)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("Start with", selection: $firstTab) {
                    Text("Claude").tag("claude")
                    Text("Codex").tag("codex")
                    Text("Terminal").tag("terminal")
                }
                .pickerStyle(.inline)
            }
            .navigationTitle("New Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", systemImage: "checkmark", action: create).disabled(macID.isEmpty)
                }
            }
            .onAppear { if macID.isEmpty { macID = store.activeTeam?.macs.first(where: \.isOnline)?.id ?? "" } }
        }
        .presentationDetents([.medium, .large])
    }

    private func create() {
        let dir = directory.trimmingCharacters(in: .whitespaces)
        let title = (dir as NSString).lastPathComponent.isEmpty ? "workspace" : (dir as NSString).lastPathComponent
        let id = "ws-\(UUID().uuidString.prefix(8).lowercased())"
        let tab = switch firstTab {
        case "terminal": WorkspaceTab(id: "\(id)-t", kind: .terminal, title: "zsh", subtitle: dir)
        case "codex": WorkspaceTab(id: "\(id)-t", kind: .agent, title: "Codex", subtitle: "New session", harness: "codex")
        default: WorkspaceTab(id: "\(id)-t", kind: .agent, title: "Claude", subtitle: "New session", harness: "claude")
        }
        store.workspaces.append(Workspace(id: id, macID: macID, title: title, directory: dir, tabs: [tab], lastActivityAt: Date()))
        theme.haptics.success()
        dismiss()
    }
}
#endif
