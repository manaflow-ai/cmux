#if os(iOS)
import CnxAgentChat
import CnxDesign
import CnxMarkdown
import CnxModel
import SwiftUI

/// SPEC 8.1 Feed tab: an X-style live timeline of agent events across every
/// workspace and tab, newest at the top. Selecting a cell opens that tab's chat.
public struct FeedScreen<SidebarItem: ToolbarContent>: View {
    let sidebarItem: SidebarItem
    @State private var store = FeedStore.shared
    @Binding private var path: [AgentChatDestination]
    @State private var position = ScrollPosition(idType: String.self)
    @State private var atTop = true
    @State private var expanded: Set<String> = []
    @State private var columnWidth: CGFloat = 0
    @State private var swipe = FeedSwipeCoordinator()
    @Environment(AppStore.self) private var appStore
    private let director = DemoDirector.shared

    /// `path`: the Feed's navigation stack, owned by the shell so the team
    /// drawer pan stays off while a chat is pushed (the back swipe wins).
    public init(path: Binding<[AgentChatDestination]>, @ToolbarContentBuilder sidebarItem: () -> SidebarItem) {
        _path = path
        self.sidebarItem = sidebarItem()
        WebMarkdownRenderer.shared.prewarm(count: 6)
    }

    public var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 0) {
                    chips
                        .id("top")
                    if store.visibleItems.isEmpty {
                        emptyState
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(store.visibleItems) { item in
                            let actions = item.swipeActions(store: store, open: { open(item) })
                            FeedSwipeRow(id: item.id, leading: actions.leading, trailing: actions.trailing, coordinator: swipe) {
                                FeedCell(item: item, store: store, open: { open(item) }, expanded: Binding(
                                    get: { expanded.contains(item.id) },
                                    set: { if $0 { expanded.insert(item.id) } else { expanded.remove(item.id) } }
                                ))
                                .background(Color.cnxBackground)
                            }
                            .id(item.id)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
                            Divider()
                        }
                    }
                    .scrollTargetLayout()
                }
            }
            .scrollPosition($position)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting, swipe.openID != nil { swipe.openID = nil }
            }
            .overlay(alignment: .bottom) { DoneUndoBar(store: store) }
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top < 60 } action: { _, top in
                atTop = top
                if top { store.clearUnseen() }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                columnWidth = width - 16 * 2 - 40 - 12
                prefetch()
            }
            .onChange(of: store.items.count) { prefetch() }
            .refreshable { try? await Task.sleep(for: .milliseconds(600)) }
            .overlay(alignment: .top) { newPill }
            .background(Color.cnxBackground)
            .navigationTitle("Feed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                sidebarItem
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
            }
            .agentChatDestinations()
        }
        .onAppear {
            FeedRouting.shared.sendPrompt = { item, text in
                guard let workspace = appStore.workspaces.first(where: { $0.id == item.workspaceID }),
                      let tab = workspace.tabs.first(where: { $0.id == item.tabID }) else { return }
                let mac = appStore.teams.flatMap(\.macs).first { $0.id == workspace.macID }?.name ?? "Mac"
                AgentSessionDirectory.shared.store(workspace: workspace, tab: tab, macName: mac).send(prompt: text)
            }
        }
        .onChange(of: director.serial) { runDemoCommand() }
    }

    private func open(_ item: FeedItem) {
        store.markRead(item.id)
        path.append(AgentChatDestination(workspaceID: item.workspaceID, tabID: item.tabID))
    }

    /// Measures upcoming bodies off screen so cells are sized before they scroll in.
    private func prefetch() {
        guard columnWidth > 0 else { return }
        WebMarkdownRenderer.shared.lastWidth = columnWidth
        WebMarkdownRenderer.shared.prefetchHeights(store.items.map(\.markdown), style: .body, width: columnWidth)
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(FeedFilter.allCases, id: \.self) { filter in
                    Button {
                        withAnimation(.cnxSnap) { store.filter = filter }
                    } label: {
                        HStack(spacing: 6) {
                            Text(filter.rawValue)
                            if filter == .needsYou, store.needsYouCount > 0 {
                                Text("\(store.needsYouCount)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.cnxOnAccent)
                                    .padding(.horizontal, 6)
                                    .frame(minWidth: 18, minHeight: 18)
                                    .background(Color.cnxAccent, in: .capsule)
                                    .contentTransition(.numericText())
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(store.filter == filter ? Color.cnxFillSelected : Color.clear, in: .capsule)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(store.filter == filter ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .padding(.vertical, 6)
        .sensoryFeedback(.selection, trigger: store.filter)
    }

    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $store.filter) {
                ForEach(FeedFilter.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.inline)
            Section("Workspaces") {
                ForEach(appStore.workspaces) { workspace in
                    Toggle(workspace.title, isOn: Binding(
                        get: { !store.mutedWorkspaces.contains(workspace.id) },
                        set: { on in
                            if on { store.mutedWorkspaces.remove(workspace.id) } else { store.mutedWorkspaces.insert(workspace.id) }
                        }
                    ))
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
        .accessibilityLabel("Filter")
    }

    @ViewBuilder
    private var newPill: some View {
        if !store.unseenNewIDs.isEmpty, !atTop {
            Button {
                withAnimation(.cnxSmooth) { position.scrollTo(id: "top") }
                store.clearUnseen()
            } label: {
                Label("\(store.unseenNewIDs.count) new", systemImage: "arrow.up")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 36)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .padding(.top, 8)
            .transition(.offset(y: -12).combined(with: .opacity))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: store.filter == .all ? "bubble.left.and.text.bubble.right" : "line.3.horizontal.decrease")
                .font(.system(size: 28))
                .padding(.bottom, 10)
            Text(store.filter == .all ? "Nothing yet" : "No matching events").font(.headline)
            Text(store.filter == .all ? "Agent updates, questions and finished tasks show up here." : "Try another filter.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            if store.filter != .all {
                Button("Show all") { store.filter = .all }
                    .buttonStyle(CnxCapsuleButtonStyle(.primary))
                    .padding(.top, 14)
            }
        }
        .padding(.top, 160)
    }

    private func runDemoCommand() {
        guard let command = director.command else { return }
        switch command {
        case .feedScroll(let id):
            withAnimation(.smooth(duration: 0.9)) { position.scrollTo(id: id, anchor: .top) }
        case .feedScrollTop:
            withAnimation(.cnxSmooth) { position.scrollTo(id: "top") }
            store.clearUnseen()
        case .feedOpen(let id):
            if let item = store.items.first(where: { $0.id == id }) { open(item) }
        case .feedSwipe(let id, let edge):
            swipe.demoReveal = (id, edge == "leading")
            swipe.demoPerform = nil
            swipe.demoSerial += 1
        case .feedSwipeAction(let id, let action):
            swipe.demoReveal = nil
            swipe.demoPerform = (id, action)
            swipe.demoSerial += 1
        case .feedSwipeClose:
            swipe.openID = nil
        default:
            break
        }
    }
}
/// "Marked done" with Undo for a few seconds after a Done swipe (Mail's undo bar).
private struct DoneUndoBar: View {
    let store: FeedStore

    var body: some View {
        ZStack {
            if let id = store.lastDoneID {
                HStack(spacing: 14) {
                    Label("Marked done", systemImage: "checkmark.circle")
                        .font(.subheadline.weight(.medium))
                    Button("Undo") { withAnimation(.cnxSmooth) { store.undoDone() } }
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 18)
                .frame(height: 44)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(.bottom, 12)
                .transition(.offset(y: 16).combined(with: .opacity))
                .task(id: id) {
                    try? await Task.sleep(for: .seconds(4))
                    if store.lastDoneID == id { withAnimation(.cnxSmooth) { store.clearDone() } }
                }
            }
        }
        .animation(.cnxSnappy, value: store.lastDoneID)
    }
}
#endif
