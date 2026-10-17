import CNMProtocol
import SwiftUI

struct HomeRoute: Hashable {
    let host: String
    let conversation: String
}

/// Conversations with Chief, laid out like the Messages list: pinned
/// conversations as large avatars, then rows with a blue unread dot.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(ShellState.self) private var shell
    @State private var query = ""

    struct Item: Identifiable, Hashable {
        var id: String { host + "/" + info.id }
        let host: String
        let hostName: String
        let info: ConversationInfo
    }

    private var items: [Item] {
        model.hosts.flatMap { host in host.conversations.map { Item(host: host.id, hostName: host.name, info: $0) } }
            .filter { item in
                query.isEmpty || item.info.title.localizedCaseInsensitiveContains(query)
                    || (item.info.lastMessage?.text.localizedCaseInsensitiveContains(query) ?? false)
            }
            .sorted { $0.info.updatedAt > $1.info.updatedAt }
    }

    private var multipleHosts: Bool { model.hosts.count > 1 }

    var body: some View {
        @Bindable var shell = shell
        NavigationStack(path: $shell.homePath) {
            Group {
                if model.hosts.isEmpty, model.hostsLoaded {
                    NoMacView()
                } else {
                    list
                }
            }
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { DrawerButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        compose()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New conversation")
                    .accessibilityIdentifier("home.compose")
                    .disabled(model.connectedHosts.isEmpty)
                }
            }
            .navigationDestination(for: HomeRoute.self) { route in
                if let host = model.host(route.host) {
                    ConversationView(host: host, conversationID: route.conversation)
                }
            }
        }
    }

    private var list: some View {
        let pinned = items.filter(\.info.pinned)
        let others = items.filter { !$0.info.pinned }
        return List {
            if !pinned.isEmpty, query.isEmpty {
                PinnedGrid(items: pinned, multipleHosts: multipleHosts) { open($0) }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 10, trailing: 0))
                    .listRowSeparator(.hidden)
            }
            ForEach(query.isEmpty ? others : items) { item in
                ConversationRow(item: item, typing: model.host(item.host)?.typing.contains(item.info.id) ?? false, showHost: multipleHosts)
                    .contentShape(.rect)
                    .onTapGesture { open(item) }
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 83 }
                    .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width - 16 }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            if item.info.unreadCount > 0 { model.host(item.host)?.markRead(item.info.id) }
                            else { model.host(item.host)?.markUnread(item.info.id) }
                        } label: {
                            Label(item.info.unreadCount > 0 ? "Read" : "Unread",
                                  systemImage: item.info.unreadCount > 0 ? "message" : "message.badge")
                        }
                        .tint(Messages.accent)
                        Button {
                            model.host(item.host)?.setPinned(item.info.id, !item.info.pinned)
                        } label: {
                            Label(item.info.pinned ? "Unpin" : "Pin", systemImage: item.info.pinned ? "pin.slash.fill" : "pin.fill")
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            model.host(item.host)?.deleteConversation(item.info.id)
                        } label: {
                            Label("Delete", systemImage: "trash.fill")
                        }
                        .tint(Color(hex: 0xFF383C))
                    }
                    .contextMenu {
                        Button {
                            if item.info.unreadCount > 0 { model.host(item.host)?.markRead(item.info.id) }
                            else { model.host(item.host)?.markUnread(item.info.id) }
                        } label: {
                            Label(item.info.unreadCount > 0 ? "Mark as Read" : "Mark as Unread",
                                  systemImage: item.info.unreadCount > 0 ? "message" : "message.badge")
                        }
                        Button {
                            model.host(item.host)?.setPinned(item.info.id, !item.info.pinned)
                        } label: {
                            Label(item.info.pinned ? "Unpin" : "Pin", systemImage: item.info.pinned ? "pin.slash" : "pin")
                        }
                        Button(role: .destructive) {
                            model.host(item.host)?.deleteConversation(item.info.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
            if items.isEmpty, !model.hosts.isEmpty {
                HostsConnectingRow()
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        // iOS 26 Messages keeps search in a floating field at the bottom.
        .searchable(text: $query)
        .refreshable { for host in model.hosts { await host.refreshAll() } }
    }

    private func open(_ item: Item) {
        shell.homePath.append(HomeRoute(host: item.host, conversation: item.info.id))
    }

    private func compose() {
        guard let host = model.connectedHosts.first else { return }
        Task {
            if let info = try? await host.createConversation(firstMessage: nil) {
                shell.homePath.append(HomeRoute(host: host.id, conversation: info.id))
            }
        }
    }
}

struct ConversationRow: View {
    let item: HomeView.Item
    let typing: Bool
    let showHost: Bool

    // Measured Messages list row (docs/IMESSAGE-SPEC.md §1.1): 86.67 pt tall,
    // 45 pt avatar at x 26, text column at x 83, time ending at x 365.7.
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Circle()
                .fill(item.info.unreadCount > 0 ? Messages.accent : .clear)
                .frame(width: 10, height: 10)
                .frame(width: 26)
                .padding(.top, 38)
            ChiefAvatar(size: 45)
                .padding(.top, 20)
                .padding(.trailing, 12)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(showHost ? "\(item.info.title) · \(item.hostName)" : item.info.title)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(item.info.updatedAt.listStamp)
                        .font(.system(size: 15))
                        .foregroundStyle(Color(light: 0x8B8B8F, dark: 0x8B8B91))
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 15, weight: .semibold))
                        .imageScale(.small)
                        .foregroundStyle(Color(light: 0xC6C6C8, dark: 0x454548))
                        .padding(.leading, 4)
                }
                .frame(height: 20.3)
                Group {
                    if typing {
                        Text("Typing…").italic()
                    } else {
                        Text(previewText)
                    }
                }
                .font(.system(size: 15))
                .foregroundStyle(Messages.secondary)
                .lineLimit(2, reservesSpace: true)
                .padding(.top, 1.4)
            }
            .padding(.top, 12)
            .padding(.trailing, 16)
        }
        .frame(height: 86.67, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.row.\(item.info.id)")
    }

    private var previewText: String {
        guard let last = item.info.lastMessage else { return String(localized: "No messages yet") }
        return last.text
    }
}

struct PinnedGrid: View {
    let items: [HomeView.Item]
    let multipleHosts: Bool
    let open: (HomeView.Item) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 18) {
            ForEach(items) { item in
                Button { open(item) } label: {
                    VStack(spacing: 6) {
                        ZStack(alignment: .topLeading) {
                            ChiefAvatar(size: 84)
                            if item.info.unreadCount > 0 {
                                Circle().fill(Color(.systemBlue)).frame(width: 14, height: 14)
                                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2.5))
                                    .offset(x: 2, y: 2)
                            }
                        }
                        Text(multipleHosts ? "\(item.info.title) · \(item.hostName)" : item.info.title)
                            .font(.system(size: 13))
                            .foregroundStyle(item.info.unreadCount > 0 ? .primary : .secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.pin.\(item.info.id)")
            }
        }
        .padding(.horizontal, 16)
    }
}

/// Chief's avatar: the cmux mark on the Messages contact gradient.
struct ChiefAvatar: View {
    var size: CGFloat = 40

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [Color(hex: 0x2E2E33), Color(hex: 0x0E0E10)], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay {
                Image("CmuxMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.56)
                    .colorInvert()
                    .brightness(0.0)
            }
    }
}

struct HostsConnectingRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            if !model.presenceKnown || model.hosts.contains(where: { if case .connecting = $0.status { true } else { false } }) {
                ProgressView()
                Text("Connecting to your Mac…")
            } else if model.connectedHosts.isEmpty {
                Image(systemName: "laptopcomputer.slash")
                Text("Your Mac is offline. Start cnm-host on it.")
            } else {
                Text("No conversations yet.")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// Shown until the first Mac is paired.
struct NoMacView: View {
    @Environment(ShellState.self) private var shell

    var body: some View {
        ContentUnavailableView {
            Label("Pair your Mac", systemImage: "laptopcomputer.and.iphone")
        } description: {
            Text("Run cnm-host on your Mac. It shows a code to enter here.")
        } actions: {
            Button("Add a Mac") { shell.showAddMac = true }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .accessibilityIdentifier("home.addMac")
        }
    }
}
