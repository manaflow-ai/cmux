#if os(iOS)
import CmuxTabsKit
import CnxDesign
import CnxModel
import SwiftUI
import UIKit

private let theme = CnxTheme.standard

extension TabsKitTheme {
    /// TabsKit on cnx tokens: true-black pages, a neutral grid wallpaper,
    /// and a neutral accent. Done keeps TabsKit's white checkmark, so the
    /// accent is a near-black in light mode and a mid gray in dark mode
    /// (the cnx white accent would hide the glyph).
    public static var cnx: TabsKitTheme {
        var tabs = TabsKitTheme()
        tabs.colors.label = theme.colors.label.color
        tabs.colors.secondaryLabel = theme.colors.label2.color
        tabs.colors.pageBackground = theme.colors.bg.color
        tabs.colors.overviewTop = TabsKitTheme.Colors.pair(0xF2F2F7, 0x1C1C1E)
        tabs.colors.overviewBottom = TabsKitTheme.Colors.pair(0xE5E5EA, 0x000000)
        tabs.colors.accent = TabsKitTheme.Colors.pair(0x1C1C1E, 0x636366)
        return tabs
    }
}

/// A workspace: its tabs in the Safari-style TabsKit chrome, opened on the
/// last tab used on this device. Pushed full screen from the Workspaces
/// list with the root tab bar and navigation bar hidden (SPEC 3.1: full
/// screen surfaces own the bottom edge). Ways back to the list: the
/// toolbar's back chevron (a tab without page history), the system edge
/// swipe, the grid's leading back circle, and "All Workspaces" in the page menu.
public struct WorkspaceScreen: View {
    @State private var source: WorkspaceTabsSource
    @State private var showsGrid: Bool
    @Environment(\.dismiss) private var dismiss
    private let director = WorkspaceDemoDirector.shared

    public init(store: AppStore, workspaceID: String, terminal: any TerminalTabContent = PlaceholderTerminalTabContent(),
                startsInGrid: Bool = false) {
        _source = State(initialValue: WorkspaceTabsSource(store: store, workspaceID: workspaceID, terminal: terminal))
        _showsGrid = State(initialValue: startsInGrid)
    }

    public var body: some View {
        TabsView(source: source, isShowingOverview: $showsGrid)
            .tabsKitTheme(.cnx)
            .overlay(alignment: .top) {
                if showsGrid {
                    gridHeader.transition(.opacity.animation(.easeOut(duration: 0.2)))
                }
            }
            .background(theme.colors.bg.color.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .background(InteractivePopEnabler())
            .onAppear { source.exit = { dismiss() } }
            .onChange(of: director.serial) { run(director.command) }
            .accessibilityIdentifier("workspace.\(source.workspaceID)")
    }

    /// The grid's top row: back to the workspace list, and which workspace
    /// this is (TabsKit draws More on the trailing side at the same height).
    private var gridHeader: some View {
        ZStack {
            VStack(spacing: 1) {
                Text(source.workspace?.title ?? "").font(.headline)
                Text(macLine).font(.footnote).foregroundStyle(theme.colors.label2.color)
            }
            .lineLimit(1)
            .frame(maxWidth: 220)
            HStack {
                Button {
                    source.exit()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(theme.colors.label.color)
                        .frame(width: 36, height: 36)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Workspaces")
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    private var macLine: String {
        guard let workspace = source.workspace else { return "" }
        let mac = source.store.teams.flatMap(\.macs).first { $0.id == workspace.macID }?.name ?? ""
        let count = workspace.tabs.count
        return "\(mac) · \(count == 1 ? "1 tab" : "\(count) tabs")"
    }

    private func run(_ command: WorkspaceDemoDirector.Command?) {
        switch command {
        case .showGrid(let shown): showsGrid = shown
        case .activate(let id):
            source.activate(id)
            if showsGrid { showsGrid = false }
        case .newTab(let option):
            if let option = source.newTabOptions.first(where: { $0.id == option }) {
                Task { _ = await source.createTab(option) }
            }
        case .close(let id): source.close(id)
        case .exit: source.exit()
        case nil: break
        }
    }
}

/// DEBUG choreography for recordings: commands the open workspace runs
/// through the same paths as its controls.
@MainActor
@Observable
public final class WorkspaceDemoDirector {
    public static let shared = WorkspaceDemoDirector()

    public enum Command: Hashable, Sendable {
        case showGrid(Bool)
        case activate(String)
        case newTab(String)
        case close(String)
        case exit
    }

    public private(set) var command: Command?
    public private(set) var serial = 0

    public init() {}

    public func post(_ command: Command) {
        self.command = command
        serial &+= 1
    }
}

/// SwiftUI disables the navigation controller's edge-swipe pop while the
/// bar is hidden. A workspace hides the bar but must still swipe back like
/// any pushed screen, so this re-enables the system recognizer (with a
/// delegate that only allows it when there is something to pop).
private struct InteractivePopEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let navigation = navigationController, let pop = navigation.interactivePopGestureRecognizer else { return }
            pop.isEnabled = true
            pop.delegate = self
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}
#endif
