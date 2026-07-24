import AppKit
import CmuxUpdater
import QuartzCore
import SwiftUI
import Testing
@testable import cmux_DEV

@Suite
@MainActor
struct SidebarHiddenPresentationTests {
    @Test
    func controllerHideReleasesLiveRowPayloadWithoutDiscardingRowIdentity() async {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let workspaceId = UUID()
        var payload: NSObject? = NSObject()
        weak var retainedPayload = payload
        var row: SidebarWorkspaceTableRowConfiguration? = makeRetainingRow(
            workspaceId: workspaceId,
            payload: payload!
        )

        controller.apply(
            rows: [row!],
            actions: makeTableActions(),
            workspaceIds: [workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        payload = nil
        row = nil
        #expect(retainedPayload != nil)

        controller.setPresentationActive(false, workspaceIds: [workspaceId])

        #expect(retainedPayload == nil)
        #expect(container.tableView.numberOfRows == 1)
    }

    @Test
    func hostedCellClearReleasesItsLiveRowPayload() {
        let cell = SidebarWorkspaceTableCellView()
        var payload: NSObject? = NSObject()
        weak var retainedPayload = payload
        var row: SidebarWorkspaceTableRowConfiguration? = makeRetainingRow(
            workspaceId: UUID(),
            payload: payload!
        )
        cell.configure(
            row: row!,
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )

        payload = nil
        row = nil
        #expect(retainedPayload != nil)
        cell.clearRetainedPayload()
        #expect(retainedPayload == nil)
    }

    @Test
    func inactivePresentationRemovesAnInstalledSpinnerAnimation() {
        let spinner = GPUSpinnerNSView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        spinner.contentLayer.add(
            CABasicAnimation(keyPath: "transform.rotation.z"),
            forKey: GPUSpinnerNSView.animationKey
        )
        #expect(spinner.contentLayer.animation(forKey: GPUSpinnerNSView.animationKey) != nil)

        spinner.isPresentationActive = false

        #expect(spinner.contentLayer.animation(forKey: GPUSpinnerNSView.animationKey) == nil)
    }

    @Test
    func visibilityToggleKeepsAppKitTableContainerMounted() async throws {
        _ = NSApplication.shared

        let previousUsesCoalescedAnchorFailsafe = WindowTerminalPortal.usesCoalescedAnchorFailsafe
        defer {
            WindowTerminalPortal.usesCoalescedAnchorFailsafe = previousUsesCoalescedAnchorFailsafe
        }

        let suiteName = "SidebarHiddenPresentationTests.AppKitSidebar.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            CmuxExtensionSidebarSelection.defaultProviderId,
            forKey: CmuxExtensionSidebarSelection.defaultsKey
        )

        let featureFlags = CmuxFeatureFlags(
            defaults: defaults,
            remoteFlagValueProvider: { _ in nil }
        )
        featureFlags.setOverride(true, for: CmuxFeatureFlags.appKitSidebarListFlag)

        let tabManager = TabManager()
        for _ in 0..<3 {
            tabManager.addWorkspace(autoWelcomeIfNeeded: false)
        }
        let sidebarState = SidebarState()
        let notificationStore = TerminalNotificationStore.shared
        var revealRowInputProjections = 0
        let root = ContentView(
            updateViewModel: UpdateStateModel(),
            windowId: UUID(),
            featureFlags: featureFlags
        )
            .environmentObject(tabManager)
            .environmentObject(notificationStore)
            .environmentObject(notificationStore.sidebarUnread)
            .environmentObject(sidebarState)
            .environmentObject(SidebarSelectionState())
            .environmentObject(FileExplorerState())
            .environmentObject(CmuxConfigStore())
            .environment(
                \.sidebarLazyContractProbe,
                SidebarLazyContractProbe(
                    workspaceRowInputProjection: { revealRowInputProjections += 1 }
                )
            )
            .defaultAppStorage(defaults)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = MainWindowHostingView(rootView: root)
        defer {
            window.contentView = nil
            window.close()
        }

        await drainMainRunLoop(for: window)
        let initialContainers = descendants(
            of: SidebarWorkspaceTableContainerView.self,
            in: window.contentView
        )
        #expect(initialContainers.count == 1)
        let initialContainer = try #require(initialContainers.first)
        let initialRowCount = initialContainer.tableView.numberOfRows
        #expect(initialRowCount > 0)
        let focusedWorkspace = try #require(tabManager.selectedWorkspace)
        let focusedPanelId = try #require(focusedWorkspace.focusedPanelId)
        let focusedPanel = try #require(focusedWorkspace.panels[focusedPanelId])
        #expect(window.makeFirstResponder(initialContainer.tableView))
        #expect(window.firstResponder === initialContainer.tableView)

        sidebarState.toggle()
        await drainMainRunLoop(for: window)
        let hiddenContainers = descendants(
            of: SidebarWorkspaceTableContainerView.self,
            in: window.contentView
        )
        #expect(hiddenContainers.count == 1)
        #expect(
            hiddenContainers.first === initialContainer,
            "Hiding the sidebar must preserve the existing AppKit table container."
        )
        let responderAfterHide = try #require(window.firstResponder)
        #expect(
            focusedPanel.ownedFocusIntent(for: responderAfterHide, in: window) != nil,
            "Hiding the sidebar must return keyboard focus to the selected main panel."
        )
        tabManager.addWorkspace(autoWelcomeIfNeeded: false)
        await drainMainRunLoop(for: window)
        #expect(
            initialContainer.tableView.numberOfRows == initialRowCount,
            "The retained native table must not apply workspace updates while hidden."
        )

        revealRowInputProjections = 0
        sidebarState.toggle()
        await drainMainRunLoop(for: window)
        let reopenedContainers = descendants(
            of: SidebarWorkspaceTableContainerView.self,
            in: window.contentView
        )
        #expect(reopenedContainers.count == 1)
        #expect(
            reopenedContainers.first === initialContainer,
            "Reopening the sidebar must reuse the existing AppKit table container."
        )
        #expect(
            initialContainer.tableView.numberOfRows > initialRowCount,
            "Reopening must reconcile the retained table from the current workspace model."
        )
        #expect(
            revealRowInputProjections == tabManager.tabs.count,
            "Reopening must project each current workspace row exactly once."
        )

        let sidebarField = NSTextField(frame: NSRect(x: 20, y: 40, width: 120, height: 24))
        window.contentView?.addSubview(sidebarField)
        #expect(window.makeFirstResponder(sidebarField))
        sidebarState.toggle()
        await drainMainRunLoop(for: window)
        let responderAfterSidebarFieldHide = try #require(window.firstResponder)
        #expect(
            focusedPanel.ownedFocusIntent(for: responderAfterSidebarFieldHide, in: window) != nil,
            "Hiding must restore main-panel focus from controls anywhere in the sidebar boundary."
        )
        sidebarState.toggle()
        await drainMainRunLoop(for: window)
        sidebarField.removeFromSuperview()

        let foreignField = NSTextField(frame: NSRect(x: 500, y: 400, width: 120, height: 24))
        window.contentView?.addSubview(foreignField)
        defer { foreignField.removeFromSuperview() }
        #expect(window.makeFirstResponder(foreignField))
        #expect(window.firstResponder === foreignField)
        sidebarState.toggle()
        await drainMainRunLoop(for: window)
        #expect(
            window.firstResponder === foreignField,
            "Hiding the sidebar must preserve focus owned by non-sidebar main content."
        )
    }

    @Test
    func persistenceIsScopedToDefaultProvider() throws {
        #expect(
            ContentView.retainsDefaultAppKitSidebar(
                appKitListEnabled: true,
                effectiveProviderId: CmuxExtensionSidebarSelection.defaultProviderId
            )
        )
        #expect(
            !ContentView.retainsDefaultAppKitSidebar(
                appKitListEnabled: true,
                effectiveProviderId: CmuxExtensionSidebarSelection.hostedExtensionsProviderId
            )
        )
        let bundledProviderId = try #require(CmuxExtensionSidebarSelection.providers.first?.descriptor.id)
        #expect(
            !ContentView.retainsDefaultAppKitSidebar(
                appKitListEnabled: true,
                effectiveProviderId: bundledProviderId
            )
        )

        let customSidebarsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-visibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: customSidebarsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: customSidebarsDirectory) }
        let customProviderId = CmuxExtensionSidebarSelection.customSidebarProviderPrefix + "lifecycle-test"
        try Data().write(to: customSidebarsDirectory.appendingPathComponent("lifecycle-test.swift"))
        CmuxExtensionSidebarSelection.withCustomSidebarsDirectoryForTesting(customSidebarsDirectory) {
            #expect(
                !ContentView.retainsDefaultAppKitSidebar(
                    appKitListEnabled: true,
                    effectiveProviderId: customProviderId
                )
            )
        }
        #expect(
            !ContentView.retainsDefaultAppKitSidebar(
                appKitListEnabled: false,
                effectiveProviderId: CmuxExtensionSidebarSelection.defaultProviderId
            )
        )
    }

    private func descendants<View: NSView>(of type: View.Type, in root: NSView?) -> [View] {
        guard let root else { return [] }
        var matches: [View] = []
        if let match = root as? View {
            matches.append(match)
        }
        for subview in root.subviews {
            matches.append(contentsOf: descendants(of: type, in: subview))
        }
        return matches
    }

    private func drainMainRunLoop(for window: NSWindow, iterations: Int = 20) async {
        for _ in 0..<iterations {
            window.contentView?.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            await Task.yield()
        }
    }

    private func makeRetainingRow(
        workspaceId: UUID,
        payload: NSObject
    ) -> SidebarWorkspaceTableRowConfiguration {
#if DEBUG
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: .light,
            globalFontMagnificationPercent: 100,
            lazyContractProbe: SidebarLazyContractProbe()
        )
#else
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: .light,
            globalFontMagnificationPercent: 100
        )
#endif
        return SidebarWorkspaceTableRowConfiguration(
            id: .workspace(workspaceId),
            workspaceId: workspaceId,
            groupId: nil,
            isGroupHeader: false,
            isPinned: false,
            environment: environment,
            equivalenceValue: TestRowContent()
        ) { [payload] _, _ in
            AnyView(TestRowContent().onAppear { _ = payload })
        }
    }

    private func makeTableActions() -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { _ in },
            closeWorkspace: { _ in },
            createWorkspaceAtEnd: {},
            createEmptyWorkspaceGroup: {},
            beginWorkspaceDrag: { _ in },
            endWorkspaceDrag: {},
            isValidWorkspaceDrag: { true },
            updateWorkspaceDrag: { _, _, _ in nil },
            performWorkspaceDrop: { _, _, _ in false },
            commitWorkspaceDropPlan: { _ in false },
            clearWorkspaceDropIndicator: {},
            currentDropIndicator: { nil },
            currentDropIndicatorScope: { .raw },
            canPerformBonsplitAction: { _, _ in false },
            moveBonsplitToExistingWorkspace: { _, _ in false },
            moveBonsplitToNewWorkspace: { _, _ in nil },
            didMoveBonsplitToWorkspace: { _ in },
            updateDragAutoscroll: {},
            setBonsplitDropTargetCollectionActive: { _ in },
            setBonsplitDropIndicator: { _ in }
        )
    }

    private func flushStagedTableMutations() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) {
                continuation.resume()
            }
        }
    }

    private struct TestRowContent: View, Equatable {
        var body: some View { EmptyView() }
    }
}
