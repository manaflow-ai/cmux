import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var store: CmxConnectionStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .compact {
            NavigationStack {
                WorkspaceListView(navigationStyle: .push)
                    .navigationDestination(for: WorkspaceNavigationRoute.self) { route in
                        TerminalDetailView()
                            .onAppear {
                                store.select(workspaceID: route.workspaceID)
                            }
                    }
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

    private var rows: [WorkspaceListRowSnapshot] {
        let selectedWorkspaceID = store.selectedWorkspaceID
        let isSidebar = horizontalSizeClass == .regular
        return store.visibleWorkspaces(matching: searchText).map { workspace in
            WorkspaceListRowSnapshot(
                workspace: workspace,
                node: store.node(for: workspace),
                isSelected: isSidebar && workspace.id == selectedWorkspaceID
            )
        }
    }

    var body: some View {
        List {
            WorkspaceSearchField(text: $searchText)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 14, trailing: 16))
                .listRowSeparator(.hidden)

            if rows.isEmpty {
                EmptyWorkspaceSearch()
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16))
            } else {
                ForEach(rows) { row in
                    WorkspaceNavigationRow(
                        workspace: row.workspace,
                        node: row.node,
                        isSelected: row.isSelected,
                        navigationStyle: navigationStyle,
                        selectWorkspace: { store.select(workspace: $0) }
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

private struct WorkspaceListRowSnapshot: Identifiable {
    let workspace: CmxWorkspace
    let node: CmxHiveNode
    let isSelected: Bool

    var id: UInt64 {
        workspace.id
    }
}

private enum WorkspaceNavigationStyle {
    case push
    case sidebar
}

private struct WorkspaceNavigationRoute: Hashable {
    var workspaceID: UInt64
}

private struct WorkspaceNavigationRow: View {
    let workspace: CmxWorkspace
    let node: CmxHiveNode
    let isSelected: Bool
    let navigationStyle: WorkspaceNavigationStyle
    let selectWorkspace: (CmxWorkspace) -> Void

    var body: some View {
        switch navigationStyle {
        case .push:
            NavigationLink(value: WorkspaceNavigationRoute(workspaceID: workspace.id)) {
                row
            }
            .accessibilityIdentifier("workspace.row.\(workspace.id)")
        case .sidebar:
            Button {
                selectWorkspace(workspace)
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var keyboardOverlap: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            TerminalHeaderBar(
                workspaces: store.workspaces,
                selectedWorkspace: store.selectedWorkspace,
                selectedWorkspaceID: store.selectedWorkspaceID,
                selectedSpaceID: store.selectedSpaceID,
                selectedTerminalID: store.selectedTerminalID,
                latencyText: store.latencyText,
                revision: store.terminalAppearanceRevision,
                showsBackButton: horizontalSizeClass == .compact,
                back: { dismiss() },
                selectWorkspace: { store.select(workspace: $0) },
                selectSpace: { store.select(space: $0) },
                selectTerminal: { space, terminal in store.select(space: space); store.select(terminal: terminal) }
            )

            GeometryReader { proxy in
                let visibleHeight = CmxTerminalVisibleBounds.height(
                    totalHeight: proxy.size.height,
                    keyboardOverlap: keyboardOverlap
                )

                VStack(spacing: 0) {
                    TerminalPane(terminal: store.selectedTerminal)
                        .id(store.selectedTerminal.id)
                        .frame(width: proxy.size.width, height: visibleHeight)

                    Color.clear
                        .frame(height: proxy.size.height - visibleHeight)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .background {
                    CmxKeyboardOverlapReader(overlap: $keyboardOverlap)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TerminalThemeChrome.background(revision: store.terminalAppearanceRevision).ignoresSafeArea())
        .ignoresSafeArea(edges: .bottom)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .navigationTitle("")
        .onAppear {
            store.refreshTerminalAppearance(colorPreference: CmxTerminalColorPreference(colorScheme: colorScheme))
            store.terminalScreenDidAppear()
        }
        .onDisappear {
            store.terminalScreenDidDisappear()
        }
        .onChange(of: colorScheme) { _, newValue in
            store.refreshTerminalAppearance(colorPreference: CmxTerminalColorPreference(colorScheme: newValue))
        }
    }
}

private struct TerminalHeaderBar: View {
    let workspaces: [CmxWorkspace]
    let selectedWorkspace: CmxWorkspace
    let selectedWorkspaceID: UInt64
    let selectedSpaceID: UInt64
    let selectedTerminalID: UInt64
    let latencyText: String?
    let revision: Int
    let showsBackButton: Bool
    let back: () -> Void
    let selectWorkspace: (CmxWorkspace) -> Void
    let selectSpace: (CmxSpace) -> Void
    let selectTerminal: (CmxSpace, CmxTerminal) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if showsBackButton {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.headline.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(TerminalThemeChrome.foreground(revision: revision))
                .accessibilityLabel(String(localized: "nav.workspaces", defaultValue: "Workspaces"))
            } else {
                Color.clear
                    .frame(width: 34, height: 34)
            }

            Spacer(minLength: 0)

            TerminalPickerMenu(
                workspaces: workspaces,
                selectedWorkspace: selectedWorkspace,
                selectedWorkspaceID: selectedWorkspaceID,
                selectedSpaceID: selectedSpaceID,
                selectedTerminalID: selectedTerminalID,
                latencyText: latencyText,
                revision: revision,
                selectWorkspace: selectWorkspace,
                selectSpace: selectSpace,
                selectTerminal: selectTerminal
            )

            Spacer(minLength: 0)

            Color.clear
                .frame(width: 34, height: 34)
        }
        .frame(height: 38)
        .padding(.horizontal, 8)
        .background(TerminalThemeChrome.background(revision: revision))
    }
}

private struct CmxKeyboardOverlapReader: UIViewRepresentable {
    @Binding var overlap: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(overlap: $overlap)
    }

    func makeUIView(context: Context) -> CmxKeyboardOverlapReaderView {
        let view = CmxKeyboardOverlapReaderView()
        view.onOverlapChange = { [weak coordinator = context.coordinator] overlap in
            coordinator?.setOverlap(overlap)
        }
        return view
    }

    func updateUIView(_ uiView: CmxKeyboardOverlapReaderView, context: Context) {
        context.coordinator.overlap = $overlap
        uiView.onOverlapChange = { [weak coordinator = context.coordinator] overlap in
            coordinator?.setOverlap(overlap)
        }
        uiView.reportCurrentOverlap()
    }

    final class Coordinator {
        var overlap: Binding<CGFloat>

        init(overlap: Binding<CGFloat>) {
            self.overlap = overlap
        }

        @MainActor
        func setOverlap(_ nextOverlap: CGFloat) {
            guard abs(overlap.wrappedValue - nextOverlap) > 0.5 else { return }
            overlap.wrappedValue = nextOverlap
        }
    }
}

private final class CmxKeyboardOverlapReaderView: UIView {
    var onOverlapChange: ((CGFloat) -> Void)?
    private let guideTracker = UIView(frame: .zero)
    private var lastOverlap: CGFloat = -1
    private var pendingOverlap: CGFloat?
    private var deliveryScheduled = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        keyboardLayoutGuide.followsUndockedKeyboard = true
        guideTracker.translatesAutoresizingMaskIntoConstraints = false
        guideTracker.isUserInteractionEnabled = false
        guideTracker.accessibilityElementsHidden = true
        addSubview(guideTracker)
        NSLayoutConstraint.activate([
            guideTracker.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            guideTracker.leadingAnchor.constraint(equalTo: leadingAnchor),
            guideTracker.widthAnchor.constraint(equalToConstant: 0),
            guideTracker.heightAnchor.constraint(equalToConstant: 0),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportCurrentOverlap()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportCurrentOverlap()
    }

    func reportCurrentOverlap() {
        let nextOverlap = CmxKeyboardOverlap.visibleHeight(
            containerBounds: bounds,
            keyboardFrame: keyboardLayoutGuide.layoutFrame
        )
        guard abs(lastOverlap - nextOverlap) > 0.5 else { return }
        lastOverlap = nextOverlap
        pendingOverlap = nextOverlap
        guard !deliveryScheduled else { return }
        deliveryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            deliveryScheduled = false
            guard let overlap = pendingOverlap else { return }
            pendingOverlap = nil
            onOverlapChange?(overlap)
        }
    }
}

private struct TerminalPickerMenu: View {
    let workspaces: [CmxWorkspace]
    let selectedWorkspace: CmxWorkspace
    let selectedWorkspaceID: UInt64
    let selectedSpaceID: UInt64
    let selectedTerminalID: UInt64
    let latencyText: String?
    let revision: Int
    let selectWorkspace: (CmxWorkspace) -> Void
    let selectSpace: (CmxSpace) -> Void
    let selectTerminal: (CmxSpace, CmxTerminal) -> Void

    var body: some View {
        Menu {
            ForEach(workspaces) { workspace in
                Button {
                    selectWorkspace(workspace)
                } label: {
                    Label(
                        workspace.title,
                        systemImage: workspace.id == selectedWorkspaceID ? "checkmark" : "rectangle.stack"
                    )
                }
            }

            Divider()

            ForEach(selectedWorkspace.spaces) { space in
                Menu {
                    Button {
                        selectSpace(space)
                    } label: {
                        Label(
                            space.title,
                            systemImage: space.id == selectedSpaceID ? "checkmark" : "rectangle.split.1x2"
                        )
                    }

                    if !space.terminals.isEmpty {
                        Divider()
                    }

                    ForEach(space.terminals) { terminal in
                        Button {
                            selectTerminal(space, terminal)
                        } label: {
                            Label(
                                terminal.title,
                                systemImage: terminal.id == selectedTerminalID ? "terminal.fill" : "terminal"
                            )
                        }
                    }
                } label: {
                    Label(
                        space.title,
                        systemImage: space.id == selectedSpaceID ? "checkmark.circle" : "rectangle.split.1x2"
                    )
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(selectedWorkspace.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                if let latencyText {
                    Text(latencyText)
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .foregroundStyle(TerminalThemeChrome.foreground(revision: revision).opacity(0.72))
                }
            }
            .foregroundStyle(TerminalThemeChrome.foreground(revision: revision))
            .accessibilityIdentifier("terminal.selector")
        }
    }
}

private struct TerminalPane: View {
    @EnvironmentObject private var store: CmxConnectionStore
    @State private var visibleGridSize: TerminalGridSize?
    let terminal: CmxTerminal
    private let showsBoundsOverlay = CmxLaunchConfiguration.showsTerminalBoundsOverlay()

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                CmxGhosttyTerminalView(
                    store: store,
                    terminalID: terminal.id,
                    renderSize: store.renderSize(for: terminal.id),
                    outputRevision: store.terminalOutputRevision,
                    hostPlatform: store.selectedHostPlatform,
                    visibleGridSize: $visibleGridSize
                )
                    .id(terminal.id)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                if showsBoundsOverlay {
                    TerminalVisibleBoundsOverlay(
                        gridSize: visibleGridSize,
                        pointSize: proxy.size,
                        revision: store.terminalAppearanceRevision
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TerminalThemeChrome.background(revision: store.terminalAppearanceRevision))
    }
}

private struct TerminalVisibleBoundsOverlay: View {
    let gridSize: TerminalGridSize?
    let pointSize: CGSize
    let revision: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(verbatim: label)
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .foregroundStyle(TerminalThemeChrome.foreground(revision: revision))
                .background(TerminalThemeChrome.background(revision: revision).opacity(0.84))
                .accessibilityIdentifier("terminal.bounds.overlay")
        }
        .allowsHitTesting(false)
    }

    private var label: String {
        let points = "\(Int(pointSize.width.rounded()))x\(Int(pointSize.height.rounded())) pt"
        guard let gridSize else {
            return "visible pending | \(points)"
        }
        return "visible \(gridSize.columns)x\(gridSize.rows) cells | \(gridSize.pixelWidth)x\(gridSize.pixelHeight) px | \(points)"
    }
}

private enum TerminalThemeChrome {
    @MainActor
    static func background(revision _: Int) -> Color {
        Color(
            GhosttyRuntime.configuredUIColor(
                named: "background",
                fallback: .black
            )
        )
    }

    @MainActor
    static func foreground(revision _: Int) -> Color {
        Color(
            GhosttyRuntime.configuredUIColor(
                named: "foreground",
                fallback: .white
            )
        )
    }

    @MainActor
    static func toolbarColorScheme(revision _: Int) -> ColorScheme {
        GhosttyRuntime.configuredUIColor(
            named: "background",
            fallback: .black
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
        guard keyboardFrame.height >= 80 else { return 0 }
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
