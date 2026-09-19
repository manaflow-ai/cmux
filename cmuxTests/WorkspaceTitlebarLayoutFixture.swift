import AppKit
import Bonsplit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceTitlebarLayoutFixture {
    let defaults: UserDefaults
    let controller: BonsplitController
    let terminalPane: PaneID
    private let suite: String
    let window: NSWindow
    private let host: NSView

    init(tabCount: Int, split: Bool) throws {
        suite = "WorkspaceTitlebarLayoutFixture.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("standard", forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set(true, forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        let controller = BonsplitController()
        self.controller = controller
        controller.configuration.appearance.tabBarHeight = WindowChromeMetrics.bonsplitTabBarHeight
        controller.configuration.appearance.enableAnimations = false
        terminalPane = try #require(controller.focusedPaneId)
        let initialTabs = controller.tabs(inPane: terminalPane)
        for index in 0..<tabCount {
            controller.createTab(title: "Terminal \(index)", kind: "terminal", inPane: terminalPane)
        }
        for tab in initialTabs { controller.closeTab(tab.id) }
        if split {
            _ = try #require(controller.splitPane(terminalPane, orientation: .horizontal, withTab: Tab(title: "Browser", kind: "browser")))
        }
        let root = ZStack(alignment: .topLeading) {
            BonsplitView(controller: controller) { tab, _ in
                Color.clear.background(WorkspaceTitlebarLayoutMarker(identifier: tab.kind == "browser" ? "Browser" : "Terminal"))
            } emptyPane: { _ in
                Color.clear
            }
            .modifier(WorkspaceContentMinimalModeSafeAreaModifier(isFullScreen: false))
            .modifier(WorkspacePresentationModeContentTopPaddingModifier(
                isFullScreen: false, titlebarPadding: 28, hostingSafeAreaTop: 0
            ))
            WorkspaceTitlebarModeLayer {
                Color.clear.frame(height: WindowChromeMetrics.appTitlebarHeight)
                    .background(WorkspaceTitlebarLayoutMarker(identifier: "Title"))
            } compactControls: {
                EmptyView()
            }
        }
        .defaultAppStorage(defaults)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        host = MainWindowHostingView(rootView: root)
        window.contentView = host
    }

    var hasTitle: Bool { marker(identifier: "Title", in: host) != nil }

    func panelFrame(identifier: String = "Terminal") throws -> NSRect {
        let view = try #require(marker(identifier: identifier, in: host))
        return view.convert(view.bounds, to: host)
    }

    func layout() async {
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            await Task.yield()
        }
    }

    func close() {
        window.contentView = nil
        window.close()
        defaults.removePersistentDomain(forName: suite)
    }

    private func marker(identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        return view.subviews.lazy.compactMap { marker(identifier: identifier, in: $0) }.first
    }
}
