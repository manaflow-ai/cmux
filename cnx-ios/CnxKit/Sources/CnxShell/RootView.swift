#if os(iOS)
import CnxDesign
import CnxFeed
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
        #if DEBUG
        .task { await DebugLaunch.run(selectTab: { selectedTab = $0 }) }
        #endif
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
                FeedScreen { SidebarToolbarItem(openSidebar: openSidebar) }
            }
            .badge(FeedStore.shared.needsYouCount)
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

#if DEBUG
/// DEBUG launch arguments: `-CnxDemo chat-feed` runs the Feed + agent chat demo driver.
struct DebugLaunch {
    @MainActor
    static func run(selectTab: (RootTab) -> Void) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-CnxDemo"), arguments.indices.contains(index + 1) else { return }
        switch arguments[index + 1] {
        case "chat-feed":
            selectTab(.feed)
            await FeedDemoScript().run()
        default:
            break
        }
    }
}
#endif
#endif
