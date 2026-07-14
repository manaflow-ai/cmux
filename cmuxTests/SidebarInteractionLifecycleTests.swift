import AppKit
import CmuxSidebar
import CmuxUpdater
import OSLog
import Observation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exercises the production sidebar in the AppKit lifecycle that exposed #8004.
@Suite(.serialized)
final class SidebarInteractionLifecycleTests {
    private static let workspaceCount = 300
    private static let realizedRowCeiling = 150
    private static let churnPasses = 36

    private final class RowBodyCounter {
        var workspaceRows = 0
        var groupHeaders = 0

        var total: Int { workspaceRows + groupHeaders }

        func reset() {
            workspaceRows = 0
            groupHeaders = 0
        }
    }

    private final class LifecycleTestWindow: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    @MainActor
    @Observable
    final class PresentationState {
        var colorScheme: ColorScheme = .light
        var tint = Color.blue
    }

    private struct PresentationHost<Content: View>: View {
        let presentation: PresentationState
        let content: Content

        var body: some View {
            content
                .tint(presentation.tint)
                .environment(\.colorScheme, presentation.colorScheme)
        }
    }

    @MainActor
    private final class Heartbeat {
        private(set) var count = 0
        private(set) var longestGap: TimeInterval = 0
        private var lastBeat = Date.now
        private var timer: Timer?

        func start() {
            lastBeat = .now
            let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = Date.now
                    self.longestGap = max(self.longestGap, now.timeIntervalSince(self.lastBeat))
                    self.lastBeat = now
                    self.count += 1
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }
    }

    private struct RuntimeFaultCounts: Equatable, CustomStringConvertible {
        let publishingDuringViewUpdate: Int
        let modifyingStateDuringViewUpdate: Int
        let reentrantHostingViewLayout: Int

        var total: Int {
            publishingDuringViewUpdate
                + modifyingStateDuringViewUpdate
                + reentrantHostingViewLayout
        }

        var description: String {
            "publishing=\(publishingDuringViewUpdate) "
                + "modifying=\(modifyingStateDuringViewUpdate) "
                + "reentrantLayout=\(reentrantHostingViewLayout)"
        }

        static func read(since start: Date) throws -> Self {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: start)
            let entries = try store.getEntries(at: position)
            var publishing = 0
            var modifying = 0
            var reentrantLayout = 0

            for entry in entries {
                let message = entry.composedMessage
                if message.contains("Publishing changes from within view updates is not allowed") {
                    publishing += 1
                }
                if message.contains("Modifying state during view update") {
                    modifying += 1
                }
                if message.contains("NSHostingView is being laid out reentrantly") {
                    reentrantLayout += 1
                }
            }

            return Self(
                publishingDuringViewUpdate: publishing,
                modifyingStateDuringViewUpdate: modifying,
                reentrantHostingViewLayout: reentrantLayout
            )
        }
    }

    @MainActor
    private final class Harness {
        let tabManager: TabManager
        let unread: SidebarUnreadModel
        let counter: RowBodyCounter
        let window: NSWindow
        let defaultsSuiteName: String

        private let updateModel = UpdateStateModel()
        private let fileExplorerState = FileExplorerState()
        private let windowID = UUID()
        private let hostingView: NSHostingView<AnyView>
        private let defaults: UserDefaults
        private let presentation = PresentationState()

        private init(
            tabManager: TabManager,
            unread: SidebarUnreadModel,
            counter: RowBodyCounter,
            window: NSWindow,
            defaultsSuiteName: String,
            defaults: UserDefaults,
            hostingView: NSHostingView<AnyView>
        ) {
            self.tabManager = tabManager
            self.unread = unread
            self.counter = counter
            self.window = window
            self.defaultsSuiteName = defaultsSuiteName
            self.defaults = defaults
            self.hostingView = hostingView
        }

        static func mount(workspaceCount: Int) async throws -> Harness {
            _ = NSApplication.shared
            _ = NSApp.setActivationPolicy(.regular)
            #expect(
                NSApp.activationPolicy() == .regular,
                "The #8004 harness must run as a foreground-capable AppKit host."
            )

            let defaultsSuiteName = "SidebarInteractionLifecycleTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            defaults.set(
                CmuxExtensionSidebarSelection.defaultProviderId,
                forKey: CmuxExtensionSidebarSelection.defaultsKey
            )

            let tabManager = TabManager(autoWelcomeIfNeeded: false)
            while tabManager.tabs.count < workspaceCount {
                autoreleasepool {
                    _ = tabManager.addWorkspace(
                        select: false,
                        eagerLoadTerminal: false,
                        autoWelcomeIfNeeded: false,
                        autoRefreshMetadata: false
                    )
                }
                if tabManager.tabs.count.isMultiple(of: 20) {
                    Self.turnMainRunLoopOnce()
                    await Task.yield()
                }
            }

            for (index, workspace) in tabManager.tabs.enumerated() {
                workspace.setCustomTitle(
                    index.isMultiple(of: 4)
                        ? "Workspace \(index) with a deliberately long title that wraps across lines"
                        : "Workspace \(index)"
                )
                if index.isMultiple(of: 3) {
                    workspace.customDescription = "Lifecycle metadata row \(index)\nSecond line"
                }
                if index.isMultiple(of: 5) {
                    workspace.statusEntries["lifecycle"] = SidebarStatusEntry(
                        key: "lifecycle",
                        value: "pass 0"
                    )
                }
            }

            let groupCandidates = Array(tabManager.tabs.prefix(24).map(\.id))
            for start in stride(from: 0, to: groupCandidates.count, by: 4) {
                let children = Array(groupCandidates[start..<min(start + 4, groupCandidates.count)])
                _ = tabManager.createWorkspaceGroup(
                    name: "Lifecycle Group \(start / 4)",
                    childWorkspaceIds: children,
                    selectAnchor: false,
                    collapseSidebarSelection: false
                )
            }

            let window = LifecycleTestWindow(
                contentRect: NSRect(x: 80, y: 80, width: 280, height: 640),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.becomesKeyOnlyIfNeeded = false
            window.hidesOnDeactivate = false
            window.title = "Sidebar Interaction Lifecycle Test"

            let unread = SidebarUnreadModel()
            let counter = RowBodyCounter()
            let placeholder = NSHostingView(rootView: AnyView(EmptyView()))
            let harness = Harness(
                tabManager: tabManager,
                unread: unread,
                counter: counter,
                window: window,
                defaultsSuiteName: defaultsSuiteName,
                defaults: defaults,
                hostingView: placeholder
            )
            placeholder.rootView = harness.rootView()
            window.contentView = placeholder
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            await drainMainRunLoop(iterations: 30)
            window.makeKey()
            await drainMainRunLoop(iterations: 4)

            #expect(window.isVisible, "The #8004 harness must use a visible NSWindow.")
            #expect(window.isKeyWindow, "The #8004 harness must use a key NSWindow.")
            return harness
        }

        func tearDown() {
            window.contentView = nil
            window.close()
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }

        func positionStationaryPointerOverWorkspaceRow() throws {
            let point = try #require(firstWorkspaceRowScreenPoint())
            let screen = try #require(NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) })
            let screenNumber = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
            let quartzPoint = CGPoint(
                x: displayBounds.minX + point.x - screen.frame.minX,
                y: displayBounds.minY + screen.frame.maxY - point.y
            )
            try #require(CGWarpMouseCursorPosition(quartzPoint) == .success)
            Self.turnMainRunLoopOnce()
            #expect(
                hypot(NSEvent.mouseLocation.x - point.x, NSEvent.mouseLocation.y - point.y) < 4,
                "The test cursor must remain over a production workspace row."
            )
        }

        func churn(pass: Int) async throws -> Int {
            let targets = Array(tabManager.tabs.prefix(6))
            for (offset, workspace) in targets.enumerated() {
                workspace.customDescription = "Lifecycle pass \(pass), workspace \(offset)\nVariable-height update \(pass % 4)"
                workspace.statusEntries["lifecycle"] = SidebarStatusEntry(
                    key: "lifecycle",
                    value: "pass \(pass)"
                )
            }
            if !targets.isEmpty {
                let target = targets[pass % targets.count]
                unread.apply(
                    totalUnreadCount: pass + 1,
                    summaries: [
                        target.id: SidebarWorkspaceUnreadSummary(
                            unreadCount: pass + 1,
                            latestNotificationText: "Lifecycle unread update \(pass)"
                        )
                    ],
                    unreadSurfaceKeys: [],
                    focusedReadIndicatorByWorkspaceId: [:],
                    manualUnreadWorkspaceIds: []
                )
            }

            presentation.colorScheme = pass.isMultiple(of: 2) ? .dark : .light
            presentation.tint = pass.isMultiple(of: 2) ? .orange : .blue
            window.appearance = NSAppearance(
                named: pass.isMultiple(of: 2) ? .darkAqua : .aqua
            )

            let scrollView = try #require(findScrollView(in: hostingView))
            let clipView = scrollView.contentView
            let maxY = max(0, (scrollView.documentView?.bounds.height ?? 0) - clipView.bounds.height)
            clipView.scroll(to: NSPoint(x: 0, y: pass.isMultiple(of: 2) ? maxY : 0))
            scrollView.reflectScrolledClipView(clipView)

            counter.reset()
            await Self.drainMainRunLoop(iterations: 6)
            return counter.total
        }

        private func rootView() -> AnyView {
            let counter = counter
            return AnyView(
                PresentationHost(
                    presentation: presentation,
                    content: VerticalTabsSidebar(
                        updateViewModel: updateModel,
                        fileExplorerState: fileExplorerState,
                        windowId: windowID,
                        onSendFeedback: {},
                        onToggleSidebar: {},
                        onNewTab: {},
                        observedWindow: window,
                        selection: .constant(.tabs),
                        selectedTabIds: .constant([]),
                        lastSidebarSelectionIndex: .constant(nil),
                        sidebarRenderWorkerClient: .constant(nil)
                    )
                    .frame(width: 280)
                    .environmentObject(tabManager)
                    .environmentObject(unread)
                    .environmentObject(CmuxConfigStore())
                    .environmentObject(TerminalNotificationStore.shared)
                    .environmentObject(SidebarState())
                    .environmentObject(SidebarSelectionState())
                    .environment(
                        \.sidebarLazyContractProbe,
                        SidebarLazyContractProbe(
                            workspaceRowBody: { counter.workspaceRows += 1 },
                            groupHeaderRowBody: { counter.groupHeaders += 1 }
                        )
                    )
                    .defaultAppStorage(defaults)
                )
            )
        }

        private func firstWorkspaceRowScreenPoint() -> NSPoint? {
            guard let scrollView = findScrollView(in: hostingView),
                  (scrollView.documentView?.bounds.height ?? 0) > scrollView.contentView.bounds.height else {
                return nil
            }
            let clipView = scrollView.contentView
            let pointInClip = NSPoint(x: clipView.bounds.midX, y: clipView.bounds.midY)
            let pointInWindow = clipView.convert(pointInClip, to: nil)
            return window.convertPoint(toScreen: pointInWindow)
        }

        private func findScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView { return scrollView }
            for subview in view.subviews {
                if let found = findScrollView(in: subview) { return found }
            }
            return nil
        }

        private static func turnMainRunLoopOnce() {
            autoreleasepool {
                _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
            }
        }

        private static func drainMainRunLoop(iterations: Int) async {
            for _ in 0..<iterations {
                turnMainRunLoopOnce()
                await Task.yield()
            }
        }
    }

    @Test
    @MainActor
    func visibleKeyWindowLifecycleChurnHasNoRuntimeFaultsOrLivelock() async throws {
        let logStart = Date.now
        let harness = try await Harness.mount(workspaceCount: Self.workspaceCount)
        defer { harness.tearDown() }
        try harness.positionStationaryPointerOverWorkspaceRow()

        let heartbeat = Heartbeat()
        heartbeat.start()
        defer { heartbeat.stop() }

        var worstRealizationPass = 0
        for pass in 0..<Self.churnPasses {
            worstRealizationPass = max(worstRealizationPass, try await harness.churn(pass: pass))
        }

        let faults = try RuntimeFaultCounts.read(since: logStart)
        print("#8004 fault counts: \(faults); heartbeat=\(heartbeat.count); longestGap=\(heartbeat.longestGap); worstRealizationPass=\(worstRealizationPass)")

        #expect(
            worstRealizationPass < Self.realizedRowCeiling,
            "A churn pass realized \(worstRealizationPass) rows; the lazy viewport bound is broken."
        )
        #expect(heartbeat.count >= Self.churnPasses)
        #expect(
            heartbeat.longestGap < 1,
            "The main run loop stopped beating for \(heartbeat.longestGap)s during sidebar churn."
        )
        #expect(
            faults == RuntimeFaultCounts(
                publishingDuringViewUpdate: 0,
                modifyingStateDuringViewUpdate: 0,
                reentrantHostingViewLayout: 0
            ),
            "The visible production sidebar emitted #8004 runtime faults: \(faults)."
        )
    }
}
