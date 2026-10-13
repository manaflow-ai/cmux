#if os(iOS)
import CnxDesign
import CnxModel
import SwiftUI

/// The app's root: four native tabs, with the team sidebar revealed underneath
/// by pushing the whole tab interface aside (ChatGPT / Claude pattern).
public struct RootView: View {
    @State private var store: AppStore
    @State private var selectedTab: RootTab = .home
    @State private var sidebar = SidebarState()

    public init(store: AppStore) {
        _store = State(initialValue: store)
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width * CnxTheme.standard.metrics.sidebarWidthFraction
            let progress = sidebar.progress(sidebarWidth: width)
            ZStack(alignment: .leading) {
                TeamSidebar(store: store, isOpen: sidebar.isOpen) {
                    withAnimation(CnxTheme.standard.motion.sidebar) { sidebar.close() }
                }
                .frame(width: width)
                .opacity(0.4 + 0.6 * progress)
                .offset(x: -24 * (1 - progress))

                tabs
                    .clipShape(.rect(cornerRadius: progress > 0 ? CnxTheme.standard.metrics.sidebarCardRadius * progress : 0, style: .continuous))
                    .overlay {
                        Color.black.opacity(0.25 * progress)
                            .clipShape(.rect(cornerRadius: CnxTheme.standard.metrics.sidebarCardRadius * progress, style: .continuous))
                            .allowsHitTesting(sidebar.isOpen)
                            .onTapGesture { withAnimation(CnxTheme.standard.motion.sidebar) { sidebar.close() } }
                    }
                    .offset(x: width * progress)
                    .ignoresSafeArea()
            }
            .simultaneousGesture(sidebarDrag(width: width))
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .environment(store)
        .sensoryFeedback(.impact(weight: .light), trigger: sidebar.isOpen)
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: RootTab.home) {
                HomeScreen(openSidebar: openSidebar)
            }
            Tab("Workspaces", systemImage: "square.stack.3d.up", value: RootTab.workspaces) {
                WorkspacesScreen(openSidebar: openSidebar)
            }
            Tab("Feed", systemImage: "bolt.horizontal", value: RootTab.feed) {
                FeedScreen(openSidebar: openSidebar)
            }
            .badge(store.feed.filter { !$0.isResolved }.count)
            Tab("Settings", systemImage: "gearshape", value: RootTab.settings) {
                SettingsScreen()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(CnxTheme.standard.palette.accent)
    }

    private func openSidebar() {
        withAnimation(CnxTheme.standard.motion.sidebar) { sidebar.open() }
    }

    private func sidebarDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .global)
            .onChanged { value in
                sidebar.track(translation: value.translation, sidebarWidth: width)
            }
            .onEnded { value in
                withAnimation(CnxTheme.standard.motion.sidebar) {
                    sidebar.settle(translation: value.translation, predicted: value.predictedEndTranslation, sidebarWidth: width)
                }
            }
    }
}

enum RootTab: Hashable {
    case home, workspaces, feed, settings
}
#endif
