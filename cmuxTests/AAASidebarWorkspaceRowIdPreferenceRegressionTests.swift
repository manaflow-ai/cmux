import AppKit
import CmuxUpdater
import SwiftUI
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AAASidebarWorkspaceRowIdPreferenceRegressionTests: XCTestCase {
    func testAAARowIdPreferenceKeyDoesNotAggregatePerRowIds() {
        let rowIds = (0..<32).map { _ in UUID() }
        var reducedRowIds: Set<UUID> = []

        for rowId in rowIds {
            SidebarWorkspaceRowIdsPreferenceKey.reduce(value: &reducedRowIds) {
                Set([rowId])
            }
        }

        XCTAssertTrue(
            reducedRowIds.isEmpty,
            "The legacy row-ID preference key must not aggregate per-row IDs. Aggregating this key performs Set.formUnion across the lazy sidebar rows in the SwiftUI/AttributeGraph layout loop reported in https://github.com/manaflow-ai/cmux/issues/5570 and https://github.com/manaflow-ai/cmux/issues/2586."
        )
    }

    @MainActor
    func testDefaultWorkspaceSidebarDoesNotPublishRowIdLayoutPreferences() {
        _ = NSApplication.shared

        let defaults = UserDefaults.standard
        let previousProviderId = defaults.object(forKey: CmuxExtensionSidebarSelection.defaultsKey)
        CmuxExtensionSidebarSelection.setProviderId(CmuxExtensionSidebarSelection.defaultProviderId)
        defer {
            if let previousProviderId {
                defaults.set(previousProviderId, forKey: CmuxExtensionSidebarSelection.defaultsKey)
            } else {
                defaults.removeObject(forKey: CmuxExtensionSidebarSelection.defaultsKey)
            }
        }

        let tabManager = TabManager(
            initialWorkspaceTitle: "Workspace 0",
            autoWelcomeIfNeeded: false
        )
        for index in 1..<32 {
            tabManager.addWorkspace(
                title: "Workspace \(index)",
                select: false,
                eagerLoadTerminal: false,
                autoWelcomeIfNeeded: false,
                autoRefreshMetadata: false
            )
        }

        var observedRowIdPreferences: [Set<UUID>] = []
        let root = SidebarWorkspaceRowIdPreferenceProbe(
            tabManager: tabManager,
            onRowIdsPreference: { rowIds in
                observedRowIdPreferences.append(rowIds)
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let hostingView = MainWindowHostingView(rootView: root)
        hostingView.frame = window.contentRect(forFrameRect: window.frame)
        window.contentView = hostingView
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        for _ in 0..<5 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            window.displayIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
        }

        let nonEmptyRowIdPreferences = observedRowIdPreferences.filter { !$0.isEmpty }
        XCTAssertTrue(
            nonEmptyRowIdPreferences.isEmpty,
            "The default workspace sidebar must not publish non-empty row-ID layout preferences in steady state. A row-wide layout preference feeds the SwiftUI/AttributeGraph layout loop reported in https://github.com/manaflow-ai/cmux/issues/5570 and https://github.com/manaflow-ai/cmux/issues/2586."
        )
    }
}

private struct SidebarWorkspaceRowIdPreferenceProbe: View {
    @State private var selection: SidebarSelection = .tabs
    @State private var selectedTabIds: Set<UUID> = []
    @State private var lastSidebarSelectionIndex: Int?

    let tabManager: TabManager
    let onRowIdsPreference: (Set<UUID>) -> Void
    private let updateViewModel = UpdateStateModel()
    private let fileExplorerState = FileExplorerState()
    private let cmuxConfigStore = CmuxConfigStore()
    private let windowId = UUID()

    var body: some View {
        VerticalTabsSidebar(
            updateViewModel: updateViewModel,
            fileExplorerState: fileExplorerState,
            windowId: windowId,
            onSendFeedback: {},
            onToggleSidebar: {},
            onNewTab: {},
            observedWindow: nil,
            selection: $selection,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex
        )
        .environmentObject(tabManager)
        .environmentObject(TerminalNotificationStore.shared)
        .environmentObject(cmuxConfigStore)
        .frame(width: 260, height: 520)
        .onPreferenceChange(SidebarWorkspaceRowIdsPreferenceKey.self) { rowIds in
            onRowIdsPreference(rowIds)
        }
    }
}
