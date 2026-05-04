import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var store: CmxConnectionStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .compact {
            NavigationStack {
                WorkspaceListView(navigationStyle: .push)
            }
        } else {
            NavigationSplitView {
                WorkspaceListView(navigationStyle: .sidebar)
            } detail: {
                TerminalDetailView()
            }
        }
    }
}

private struct WorkspaceListView: View {
    @EnvironmentObject private var store: CmxConnectionStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var searchText = ""
    let navigationStyle: WorkspaceNavigationStyle

    private var workspaces: [CmxWorkspace] {
        store.visibleWorkspaces(matching: searchText)
    }

    var body: some View {
        List {
            WorkspaceSearchField(text: $searchText)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 14, trailing: 16))
                .listRowSeparator(.hidden)

            if workspaces.isEmpty {
                EmptyWorkspaceSearch()
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16))
            } else {
                ForEach(workspaces) { workspace in
                    let node = store.node(for: workspace)
                    WorkspaceNavigationRow(
                        workspace: workspace,
                        node: node,
                        isSelected: horizontalSizeClass == .regular && workspace.id == store.selectedWorkspaceID,
                        navigationStyle: navigationStyle
                    )
                    .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 12))
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(String(localized: "nav.workspaces", defaultValue: "Workspaces"))
        .navigationBarTitleDisplayMode(.large)
    }
}

private enum WorkspaceNavigationStyle {
    case push
    case sidebar
}

private struct WorkspaceNavigationRow: View {
    @EnvironmentObject private var store: CmxConnectionStore
    let workspace: CmxWorkspace
    let node: CmxHiveNode
    let isSelected: Bool
    let navigationStyle: WorkspaceNavigationStyle

    var body: some View {
        switch navigationStyle {
        case .push:
            NavigationLink {
                TerminalDetailView()
                    .onAppear {
                        store.select(workspace: workspace)
                    }
            } label: {
                row
            }
            .accessibilityIdentifier("workspace.row.\(workspace.id)")
        case .sidebar:
            Button {
                store.select(workspace: workspace)
            } label: {
                row
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workspace.row.\(workspace.id)")
        }
    }

    private var row: some View {
        WorkspaceConversationRow(
            workspace: workspace,
            node: node,
            isSelected: isSelected
        )
    }
}

private struct WorkspaceSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(String(localized: "home.search.prompt", defaultValue: "Search workspaces"), text: $text)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("workspace.search")
    }
}

private struct WorkspaceConversationRow: View {
    let workspace: CmxWorkspace
    let node: CmxHiveNode
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(avatarGradient)
                    .frame(width: 48, height: 48)

                Image(systemName: node.symbolName)
                    .font(.headline)
                    .foregroundStyle(.white)

                if workspace.unread {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if workspace.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(workspace.title)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer(minLength: 10)

                    Text(relativeTimestamp)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(workspace.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Circle()
                        .fill(node.isOnline ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(node.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(
                        String(
                            format: String(localized: "workspace.row.detail", defaultValue: "%d spaces, %d terminals"),
                            workspace.spaces.count,
                            workspace.spaces.reduce(0) { $0 + $1.terminals.count }
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, isSelected ? 10 : 0)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var avatarGradient: LinearGradient {
        let colors: [Color]
        switch node.id % 3 {
        case 0:
            colors = [Color.blue, Color.cyan]
        case 1:
            colors = [Color.green, Color.teal]
        default:
            colors = [Color.indigo, Color.orange]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var relativeTimestamp: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(workspace.lastActivity) {
            return workspace.lastActivity.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(workspace.lastActivity) {
            return String(localized: "home.timestamp.yesterday", defaultValue: "Yesterday")
        }
        return workspace.lastActivity.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits))
    }
}

private struct EmptyWorkspaceSearch: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(String(localized: "home.search.empty.title", defaultValue: "No Workspaces"))
                .font(.headline)
            Text(String(localized: "home.search.empty.body", defaultValue: "No matching workspace is available on your signed-in nodes."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

private struct TerminalDetailView: View {
    @EnvironmentObject private var store: CmxConnectionStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var keyboardOverlap: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let visibleHeight = CmxTerminalVisibleBounds.height(
                totalHeight: proxy.size.height,
                keyboardOverlap: keyboardOverlap
            )

            VStack(spacing: 0) {
                TerminalPane(terminal: store.selectedTerminal)
                    .frame(width: proxy.size.width, height: visibleHeight)

                Color.clear
                    .frame(height: proxy.size.height - visibleHeight)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
                updateKeyboardOverlap(notification: notification, containerFrame: proxy.frame(in: .global))
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { notification in
                updateKeyboardOverlap(notification: notification, containerFrame: proxy.frame(in: .global))
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { notification in
                updateKeyboardOverlap(notification: notification, containerFrame: proxy.frame(in: .global))
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardOverlap = 0
            }
            .onAppear {
                store.refreshTerminalAppearance(colorPreference: CmxTerminalColorPreference(colorScheme: colorScheme))
            }
            .onChange(of: colorScheme) { _, newValue in
                store.refreshTerminalAppearance(colorPreference: CmxTerminalColorPreference(colorScheme: newValue))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TerminalThemeChrome.background(revision: store.terminalAppearanceRevision).ignoresSafeArea())
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                TerminalPickerMenu()
            }
        }
        .toolbarBackground(TerminalThemeChrome.background(revision: store.terminalAppearanceRevision), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(TerminalThemeChrome.toolbarColorScheme(revision: store.terminalAppearanceRevision), for: .navigationBar)
    }

    private func updateKeyboardOverlap(notification: Notification, containerFrame: CGRect) {
        guard let keyboardFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else {
            keyboardOverlap = 0
            return
        }
        keyboardOverlap = CmxKeyboardOverlap.visibleHeight(
            containerBounds: containerFrame,
            keyboardFrame: keyboardFrame
        )
    }
}

private struct TerminalPickerMenu: View {
    @EnvironmentObject private var store: CmxConnectionStore

    var body: some View {
        Menu {
            ForEach(store.workspaces) { workspace in
                Button {
                    store.select(workspace: workspace)
                } label: {
                    Label(
                        workspace.title,
                        systemImage: workspace.id == store.selectedWorkspaceID ? "checkmark" : "rectangle.stack"
                    )
                }
            }

            Divider()

            ForEach(store.selectedWorkspace.spaces) { space in
                Menu {
                    Button {
                        store.select(space: space)
                    } label: {
                        Label(
                            space.title,
                            systemImage: space.id == store.selectedSpaceID ? "checkmark" : "rectangle.split.1x2"
                        )
                    }

                    if !space.terminals.isEmpty {
                        Divider()
                    }

                    ForEach(space.terminals) { terminal in
                        Button {
                            store.select(space: space)
                            store.select(terminal: terminal)
                        } label: {
                            Label(
                                terminal.title,
                                systemImage: terminal.id == store.selectedTerminal.id ? "terminal.fill" : "terminal"
                            )
                        }
                    }
                } label: {
                    Label(
                        space.title,
                        systemImage: space.id == store.selectedSpaceID ? "checkmark.circle" : "rectangle.split.1x2"
                    )
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(store.selectedWorkspace.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(TerminalThemeChrome.foreground(revision: store.terminalAppearanceRevision))
            .accessibilityIdentifier("terminal.selector")
        }
    }
}

private struct TerminalPane: View {
    @EnvironmentObject private var store: CmxConnectionStore
    let terminal: CmxTerminal

    var body: some View {
        GeometryReader { proxy in
            CmxGhosttyTerminalView(
                store: store,
                terminalID: terminal.id,
                hostPlatform: store.selectedHostPlatform
            )
                .id(terminal.id)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TerminalThemeChrome.background(revision: store.terminalAppearanceRevision))
    }
}

private enum TerminalThemeChrome {
    @MainActor
    static func background(revision _: Int) -> Color {
        Color(
            GhosttyRuntime.configuredUIColor(
                named: "background",
                fallback: UIColor(red: 0x27 / 255, green: 0x28 / 255, blue: 0x22 / 255, alpha: 1)
            )
        )
    }

    @MainActor
    static func foreground(revision _: Int) -> Color {
        Color(
            GhosttyRuntime.configuredUIColor(
                named: "foreground",
                fallback: UIColor(red: 0xfd / 255, green: 0xff / 255, blue: 0xf1 / 255, alpha: 1)
            )
        )
    }

    @MainActor
    static func toolbarColorScheme(revision _: Int) -> ColorScheme {
        GhosttyRuntime.configuredUIColor(
            named: "background",
            fallback: UIColor(red: 0x27 / 255, green: 0x28 / 255, blue: 0x22 / 255, alpha: 1)
        ).cmxIsDark ? .dark : .light
    }
}

private extension CmxTerminalColorPreference {
    init(colorScheme: ColorScheme) {
        self = colorScheme == .light ? .light : .dark
    }
}

enum CmxKeyboardOverlap {
    static func visibleHeight(containerBounds: CGRect, keyboardFrame: CGRect) -> CGFloat {
        guard !containerBounds.isNull,
              !containerBounds.isEmpty,
              !keyboardFrame.isNull,
              !keyboardFrame.isEmpty else { return 0 }
        guard keyboardFrame.minY > containerBounds.minY else { return 0 }
        guard keyboardFrame.maxY >= containerBounds.maxY - 1 else { return 0 }
        let overlap = containerBounds.maxY - max(containerBounds.minY, keyboardFrame.minY)
        return max(0, min(containerBounds.height, overlap))
    }
}

enum CmxTerminalVisibleBounds {
    static func height(totalHeight: CGFloat, keyboardOverlap: CGFloat) -> CGFloat {
        guard totalHeight > 0 else { return 0 }
        return max(0, totalHeight - max(0, min(totalHeight, keyboardOverlap)))
    }
}

private extension UIColor {
    var cmxIsDark: Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return true }
        let luminance = (0.299 * red) + (0.587 * green) + (0.114 * blue)
        return luminance < 0.55
    }
}
