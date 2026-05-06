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
                        selectWorkspace: { store.select(workspace: $0) },
                        togglePinned: { store.togglePinned(for: $0) },
                        toggleUnread: { store.toggleUnread(for: $0) },
                        prefetchWorkspace: { store.prefetch(workspace: $0) }
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
    let togglePinned: (CmxWorkspace) -> Void
    let toggleUnread: (CmxWorkspace) -> Void
    let prefetchWorkspace: (CmxWorkspace) -> Void

    var body: some View {
        Group {
            switch navigationStyle {
            case .push:
                NavigationLink(value: WorkspaceNavigationRoute(workspaceID: workspace.id)) {
                    row
                }
            case .sidebar:
                Button {
                    selectWorkspace(workspace)
                } label: {
                    row
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityIdentifier("workspace.row.\(workspace.id)")
        .onAppear {
            prefetchWorkspace(workspace)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                toggleUnread(workspace)
            } label: {
                Label(
                    workspace.unread
                        ? String(localized: "home.action.mark_read", defaultValue: "Read")
                        : String(localized: "home.action.mark_unread", defaultValue: "Unread"),
                    systemImage: workspace.unread ? "message" : "message.badge"
                )
            }
            .tint(.blue)
            .accessibilityIdentifier("workspace.action.unread.\(workspace.id)")

            Button {
                togglePinned(workspace)
            } label: {
                Label(
                    workspace.pinned
                        ? String(localized: "home.action.unpin", defaultValue: "Unpin")
                        : String(localized: "home.action.pin", defaultValue: "Pin"),
                    systemImage: workspace.pinned ? "pin.slash.fill" : "pin.fill"
                )
            }
            .tint(.orange)
            .accessibilityIdentifier("workspace.action.pin.\(workspace.id)")
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
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let visibleHeight = CmxTerminalVisibleBounds.height(
                    totalHeight: proxy.size.height,
                    keyboardOverlap: keyboardOverlap
                )

                VStack(spacing: 0) {
                    if store.canRenderSelectedTerminal, store.selectedTerminalOutputIsReady {
                        TerminalPane(terminal: store.selectedTerminal)
                            .id(terminalSurfaceIdentity)
                            .frame(width: proxy.size.width, height: visibleHeight)
                    } else {
                        TerminalLoadingPane(
                            statusText: store.statusText,
                            revision: store.terminalAppearanceRevision
                        )
                            .frame(width: proxy.size.width, height: visibleHeight)
                    }

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
        .navigationTitle(store.selectedWorkspace.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(TerminalThemeChrome.background(revision: store.terminalAppearanceRevision), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(TerminalThemeChrome.toolbarColorScheme(revision: store.terminalAppearanceRevision), for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                TerminalPickerMenu(
                    workspaces: store.workspaces,
                    selectedWorkspace: store.selectedWorkspace,
                    selectedWorkspaceID: store.selectedWorkspaceID,
                    selectedSpaceID: store.selectedSpaceID,
                    selectedTerminalID: store.selectedTerminalID,
                    latencyText: store.latencyText,
                    revision: store.terminalAppearanceRevision,
                    selectWorkspace: { store.select(workspace: $0) },
                    selectSpace: { store.select(space: $0) },
                    selectTerminal: { space, terminal in store.select(space: space); store.select(terminal: terminal) }
                )
            }
        }
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

    private var terminalSurfaceIdentity: String {
        "\(store.selectedWorkspaceID)-\(store.selectedSpaceID)-\(store.selectedTerminal.id)"
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
    @State private var surfaceResetNonce = 0
    let terminal: CmxTerminal
    private let showsBoundsOverlay = CmxLaunchConfiguration.showsTerminalBoundsOverlay()

    private var surfaceIdentity: String {
        "\(store.selectedWorkspaceID)-\(store.selectedSpaceID)-\(terminal.id)-\(surfaceResetNonce)"
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                CmxGhosttyTerminalView(
                    store: store,
                    terminalID: terminal.id,
                    renderSize: store.renderSize(for: terminal.id),
                    outputRevision: store.terminalOutputRevision,
                    hostPlatform: store.selectedHostPlatform,
                    visibleGridSize: $visibleGridSize,
                    surfaceResetNonce: $surfaceResetNonce
                )
                    .id(surfaceIdentity)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                if showsBoundsOverlay {
                    TerminalVisibleBoundsOverlay(
                        gridSize: visibleGridSize,
                        renderSize: store.renderSize(for: terminal.id),
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

private struct TerminalLoadingPane: View {
    let statusText: String
    let revision: Int

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(TerminalThemeChrome.foreground(revision: revision))
            Text(String(localized: "terminal.loading.title", defaultValue: "Loading terminal"))
                .font(.callout.weight(.semibold))
            Text(statusText)
                .font(.caption.monospacedDigit())
                .opacity(0.72)
        }
        .foregroundStyle(TerminalThemeChrome.foreground(revision: revision))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TerminalThemeChrome.background(revision: revision))
        .accessibilityIdentifier("terminal.loading")
    }
}

private struct TerminalVisibleBoundsOverlay: View {
    @Environment(\.displayScale) private var displayScale
    let gridSize: TerminalGridSize?
    let renderSize: CmxTerminalSize?
    let pointSize: CGSize
    let revision: Int

    var body: some View {
        let borderSize = TerminalVisibleBoundsOverlayStyle.borderSize(
            pointSize: pointSize,
            gridSize: gridSize,
            renderSize: renderSize,
            displayScale: displayScale
        )
        let labelOrigin = TerminalVisibleBoundsOverlayStyle.labelOrigin(
            pointSize: pointSize,
            borderSize: borderSize
        )

        ZStack(alignment: .topLeading) {
            if TerminalVisibleBoundsOverlayStyle.showsBorder(pointSize: borderSize) {
                Rectangle()
                    .strokeBorder(
                        TerminalVisibleBoundsOverlayStyle.borderColor(revision: revision),
                        lineWidth: TerminalVisibleBoundsOverlayStyle.borderWidth
                    )
                    .frame(width: borderSize.width, height: borderSize.height)
                    .accessibilityIdentifier("terminal.bounds.border")
            }

            if let labelOrigin {
                Text(verbatim: label)
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .foregroundStyle(TerminalThemeChrome.foreground(revision: revision))
                    .background(TerminalThemeChrome.background(revision: revision).opacity(0.84))
                    .offset(x: labelOrigin.x, y: labelOrigin.y)
                    .accessibilityIdentifier("terminal.bounds.overlay")
            }
        }
        .frame(width: pointSize.width, height: pointSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var label: String {
        let points = "\(Int(pointSize.width.rounded()))x\(Int(pointSize.height.rounded())) pt"
        guard let gridSize else {
            return "visible pending | \(points)"
        }
        if let renderSize {
            return "visible \(renderSize.cols)x\(renderSize.rows) cells | \(points)"
        }
        return "visible \(gridSize.columns)x\(gridSize.rows) cells | \(gridSize.pixelWidth)x\(gridSize.pixelHeight) px | \(points)"
    }
}

enum TerminalVisibleBoundsOverlayStyle {
    static let borderWidth: CGFloat = 1
    private static let minimumBorderLength: CGFloat = 12
    private static let minimumLabelWidth: CGFloat = 168
    private static let labelHeight: CGFloat = 18
    private static let labelGap: CGFloat = 4

    static func showsBorder(pointSize: CGSize) -> Bool {
        pointSize.width >= minimumBorderLength && pointSize.height >= minimumBorderLength
    }

    static func borderSize(
        pointSize: CGSize,
        gridSize: TerminalGridSize?,
        renderSize: CmxTerminalSize? = nil,
        displayScale: CGFloat
    ) -> CGSize {
        guard pointSize.width > 0, pointSize.height > 0 else { return .zero }
        guard let gridSize,
              gridSize.pixelWidth > 0,
              gridSize.pixelHeight > 0,
              gridSize.columns > 0,
              gridSize.rows > 0 else {
            return .zero
        }

        let scale = max(displayScale, 1)
        guard let renderSize else {
            return CGSize(
                width: min(pointSize.width, ceil(CGFloat(gridSize.pixelWidth) / scale)),
                height: min(pointSize.height, ceil(CGFloat(gridSize.pixelHeight) / scale))
            )
        }
        let columns = max(1, renderSize.cols)
        let rows = max(1, renderSize.rows)
        let cellWidth = CGFloat(gridSize.pixelWidth) / CGFloat(gridSize.columns)
        let cellHeight = CGFloat(gridSize.pixelHeight) / CGFloat(gridSize.rows)
        return CGSize(
            width: min(pointSize.width, ceil(cellWidth * CGFloat(columns) / scale)),
            height: min(pointSize.height, ceil(cellHeight * CGFloat(rows) / scale))
        )
    }

    static func labelOrigin(pointSize: CGSize, borderSize: CGSize) -> CGPoint? {
        guard showsBorder(pointSize: borderSize) else { return nil }
        let trailingSpace = pointSize.width - borderSize.width
        if trailingSpace >= minimumLabelWidth + labelGap {
            return CGPoint(x: borderSize.width + labelGap, y: 0)
        }
        let bottomSpace = pointSize.height - borderSize.height
        if bottomSpace >= labelHeight + labelGap {
            return CGPoint(x: 0, y: borderSize.height + labelGap)
        }
        return nil
    }

    @MainActor
    static func borderColor(revision: Int) -> Color {
        TerminalThemeChrome.foreground(revision: revision)
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
