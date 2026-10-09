#if os(iOS)
import CNDesign
public import CNTransport
public import SwiftUI
import UIKit

/// The Chief / Conversations home: an iMessage-style list of conversations
/// with Chief pinned at the top, pushing into message threads. UIKit inside
/// (for animation fidelity), SwiftUI outside. Usable from both app shells.
public struct ConversationsRoot: View {
    let connection: HostConnection

    public init(connection: HostConnection) {
        self.connection = connection
    }

    @Environment(\.cnLeadingBarItem) private var leadingItem
    @Environment(\.cnShellRoute) private var route
    @Environment(\.cnHostedInTabBar) private var hostedInTabBar
    @State private var threadVisible = false

    public var body: some View {
        ConversationsContainer(connection: connection, leadingItem: leadingItem, route: route, hostedInTabBar: hostedInTabBar,
                               threadVisible: $threadVisible)
            .ignoresSafeArea(.all)
            // Messages hides the tab bar inside a thread. Scoped to this tab:
            // the bar returns on pop and whenever another tab is selected.
            .toolbarVisibility(threadVisible ? .hidden : .automatic, for: .tabBar)
            .animation(.spring(response: 0.28, dampingFraction: 1), value: threadVisible)
    }
}

private struct ConversationsContainer: UIViewControllerRepresentable {
    let connection: HostConnection
    let leadingItem: AnyView?
    let route: CNShellRoute?
    let hostedInTabBar: Bool
    @Binding var threadVisible: Bool

    func makeUIViewController(context: Context) -> ConvNavigationController {
        let store = ConversationsStore(connection: connection)
        let nav = ConvNavigationController(store: store)
        store.start()
        nav.list.setLeadingItem(leadingItem)
        nav.hostedInTabBarHint = hostedInTabBar
        let visible = $threadVisible
        nav.onThreadVisibilityChange = { v in
            Task { @MainActor in if visible.wrappedValue != v { visible.wrappedValue = v } }
        }
        nav.handle(route)
        return nav
    }

    func updateUIViewController(_ controller: ConvNavigationController, context: Context) {
        if controller.store.connection !== connection {
            controller.replaceStore(ConversationsStore(connection: connection))
        }
        controller.list.setLeadingItem(leadingItem)
        controller.hostedInTabBarHint = hostedInTabBar
        controller.handle(route)
    }

    static func dismantleUIViewController(_ controller: ConvNavigationController, coordinator: ()) {
        controller.store.stop()
    }
}
#endif
