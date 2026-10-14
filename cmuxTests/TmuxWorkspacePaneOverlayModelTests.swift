import Foundation
import AppKit
import Bonsplit
import CmuxNotifications
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TmuxWorkspacePaneOverlayRenderState {
    /// Preserves legacy overlay fixtures inside the test target while keeping
    /// every production construction explicit about the configured color.
    init(
        workspaceId: UUID,
        unreadRects: [CGRect],
        flashRect: CGRect?,
        activePaneBorderRect: CGRect? = nil,
        activePaneBorderColorHex: String? = nil,
        flashToken: UInt64,
        flashReason: WorkspaceAttentionFlashReason?
    ) {
        self.init(
            workspaceId: workspaceId,
            unreadRects: unreadRects,
            flashRect: flashRect,
            activePaneBorderRect: activePaneBorderRect,
            activePaneBorderColorHex: activePaneBorderColorHex,
            flashToken: flashToken,
            flashReason: flashReason,
            workspaceAttentionColor: WorkspaceAttentionColor(configuredHex: nil)
        )
    }
}

@Suite("tmux workspace pane overlay model")
struct TmuxWorkspacePaneOverlayModelTests {
    @Test @MainActor
    func windowAccessorSkipsUnchangedOverlayRefreshes() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        let coordinator = WindowAccessor.Coordinator()

        #expect(coordinator.shouldInvoke(window: window, dedupeByWindow: true, refreshID: 1))
        #expect(!coordinator.shouldInvoke(window: window, dedupeByWindow: true, refreshID: 1))
        #expect(coordinator.shouldInvoke(window: window, dedupeByWindow: true, refreshID: 2))
    }

    @Test @MainActor
    func overlayCoordinatorRendersOnceForEqualSnapshots() {
        let coordinator = TmuxWorkspacePaneOverlayCoordinator()
        let inputs = TmuxWorkspacePaneOverlayInputs(
            target: .surface,
            settings: TmuxWorkspacePaneOverlaySettings(
                activePaneBorderColorHex: nil,
                rightSidebarOwnsInputFocus: false,
                workspaceAttentionColor: WorkspaceAttentionColor(configuredHex: nil)
            )
        )
        let snapshot = TmuxWorkspacePaneOverlayRefreshSnapshot(
            inputs: inputs,
            window: ObjectIdentifier(NSWindow(
                contentRect: .zero,
                styleMask: [],
                backing: .buffered,
                defer: true
            )),
            referenceView: nil,
            referenceBounds: nil,
            exactRects: [:],
            effectiveLayout: nil
        )
        var renderCount = 0

        #expect(coordinator.update(snapshot: snapshot) { renderCount += 1 })
        #expect(!coordinator.update(snapshot: snapshot) { renderCount += 1 })
        #expect(renderCount == 1)
    }

    @Test @MainActor
    func overlayCoordinatorRendersWhenEffectiveLayoutChanges() {
        let coordinator = TmuxWorkspacePaneOverlayCoordinator()
        let inputs = TmuxWorkspacePaneOverlayInputs(
            target: .surface,
            settings: TmuxWorkspacePaneOverlaySettings(
                activePaneBorderColorHex: nil,
                rightSidebarOwnsInputFocus: false,
                workspaceAttentionColor: WorkspaceAttentionColor(configuredHex: nil)
            )
        )
        let window = ObjectIdentifier(NSWindow(
            contentRect: .zero,
            styleMask: [],
            backing: .buffered,
            defer: true
        ))
        let firstLayout = LayoutSnapshot(
            containerFrame: PixelRect(x: 0, y: 0, width: 100, height: 100),
            panes: [],
            focusedPaneId: nil,
            timestamp: 0
        )
        let secondLayout = LayoutSnapshot(
            containerFrame: PixelRect(x: 0, y: 0, width: 120, height: 100),
            panes: [],
            focusedPaneId: nil,
            timestamp: 0
        )
        func makeSnapshot(_ layout: LayoutSnapshot) -> TmuxWorkspacePaneOverlayRefreshSnapshot {
            TmuxWorkspacePaneOverlayRefreshSnapshot(
                inputs: inputs,
                window: window,
                referenceView: nil,
                referenceBounds: nil,
                exactRects: [:],
                effectiveLayout: layout
            )
        }
        var renderCount = 0

        #expect(coordinator.update(snapshot: makeSnapshot(firstLayout)) { renderCount += 1 })
        #expect(coordinator.update(snapshot: makeSnapshot(secondLayout)) { renderCount += 1 })
        #expect(renderCount == 2)
    }

    @Test @MainActor
    func refreshIgnoresLiveLayoutSamplingTimestamp() {
        let defaults = UserDefaults(suiteName: "TmuxWorkspacePaneOverlayModelTests")!
        defer { defaults.removePersistentDomain(forName: "TmuxWorkspacePaneOverlayModelTests") }
        defaults.removePersistentDomain(forName: "TmuxWorkspacePaneOverlayModelTests")
        defaults.set(true, forKey: TmuxOverlayExperimentSettings.enabledKey)
        defaults.set(TmuxOverlayExperimentTarget.bonsplitPane.rawValue,
                     forKey: TmuxOverlayExperimentSettings.targetKey)
        let observer = TmuxOverlayExperimentTargetObserver(defaults: defaults)
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let builder = TmuxWorkspacePaneOverlayStateBuilder(
            tabManager: tabManager,
            sidebarUnread: SidebarUnreadModel(),
            experiment: observer,
            notificationStore: TerminalNotificationStore.shared,
            settings: TmuxWorkspacePaneOverlaySettings(
                activePaneBorderColorHex: nil,
                rightSidebarOwnsInputFocus: false,
                workspaceAttentionColor: WorkspaceAttentionColor(configuredHex: nil)
            )
        )
        let coordinator = TmuxWorkspacePaneOverlayCoordinator()
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        let layout = LayoutSnapshot(
            containerFrame: PixelRect(x: 0, y: 0, width: 100, height: 100),
            panes: [],
            focusedPaneId: nil,
            timestamp: 1
        )
        var laterLayout = layout
        laterLayout = LayoutSnapshot(
            containerFrame: layout.containerFrame,
            panes: layout.panes,
            focusedPaneId: layout.focusedPaneId,
            timestamp: 2
        )

        #expect(coordinator.refresh(builder: builder, in: window, liveLayoutSnapshot: layout))
        #expect(!coordinator.refresh(builder: builder, in: window, liveLayoutSnapshot: laterLayout))
    }

    @Test @MainActor
    func tracksActivePaneBorder() {
        let model = TmuxWorkspacePaneOverlayModel()
        let borderRect = CGRect(x: 8, y: 12, width: 320, height: 180)
        let attentionColor = WorkspaceAttentionColor(configuredHex: "#FF69B4")

        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: UUID(),
            unreadRects: [],
            flashRect: nil,
            activePaneBorderRect: borderRect,
            activePaneBorderColorHex: "#33AAFF",
            flashToken: 0,
            flashReason: nil,
            workspaceAttentionColor: attentionColor
        ))

        #expect(model.activePaneBorderRect == borderRect)
        #expect(model.activePaneBorderColorHex == "#33AAFF")
        #expect(model.workspaceAttentionColor == attentionColor)

        model.clear()

        #expect(model.activePaneBorderRect == nil)
        #expect(model.activePaneBorderColorHex == nil)
        #expect(model.workspaceAttentionColor == WorkspaceAttentionColor(configuredHex: nil))
    }
}
