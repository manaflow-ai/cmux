import Testing
import AppKit
import CmuxUpdater
import CoreGraphics
import SwiftUI
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class WorkspaceContentViewManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol, Sendable {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var _now = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []

    var now: Instant {
        lock.lock()
        defer { lock.unlock() }
        return _now
    }

    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance _: Duration?) async throws {
        try Task.checkCancellation()
        let readyNow: Bool = {
            lock.lock()
            defer { lock.unlock() }
            return deadline <= _now
        }()
        if readyNow { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            if deadline <= _now {
                lock.unlock()
                continuation.resume()
                return
            }
            sleepers.append(Sleeper(deadline: deadline, continuation: continuation))
            lock.unlock()
        }
    }

    func advance(by duration: Duration) {
        lock.lock()
        _now = _now.advanced(by: duration)
        let due = sleepers.filter { $0.deadline <= _now }
        sleepers.removeAll { $0.deadline <= _now }
        lock.unlock()
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }
}

@Suite(.serialized)
final class WorkspaceContentViewVisibilityTests {
    private final class MinimalModeBodyProbeCounts {
        var contentViewBody = 0
        var workspaceContentBody = 0
        var verticalTabsSidebarBody = 0

        func reset() {
            contentViewBody = 0
            workspaceContentBody = 0
            verticalTabsSidebarBody = 0
        }
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func sourceText(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private static func lineNumber(in source: String, at index: String.Index) -> Int {
        source[..<index].reduce(into: 1) { lineNumber, character in
            if character == "\n" {
                lineNumber += 1
            }
        }
    }

    private static func lineReference(in source: String, at index: String.Index) -> String {
        let lineStart = source[..<index].lastIndex(of: "\n").map { source.index(after: $0) } ?? source.startIndex
        let lineEnd = source[index...].firstIndex(of: "\n") ?? source.endIndex
        let line = source[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces)
        return "\(lineNumber(in: source, at: index)): \(line)"
    }

    @MainActor
    private func drainMainActorTasks() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    private static func restoreFocusTarget(
        workspaceId: UUID = UUID(),
        panelId: UUID = UUID(),
        intent: PanelFocusIntent = .panel
    ) -> CommandPaletteRestoreFocusTarget {
        CommandPaletteRestoreFocusTarget(
            workspaceId: workspaceId,
            panelId: panelId,
            intent: intent
        )
    }

    private static func functionBody(named name: String, in source: String) throws -> String {
        let declaration = "private func \(name)"
        let declarationRange = try #require(source.range(of: declaration))
        let bodyStart = try #require(source[declarationRange.upperBound...].firstIndex(of: "{"))
        var depth = 0
        var index = bodyStart
        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[bodyStart...index])
                }
            default:
                break
            }
            index = source.index(after: index)
        }
        Issue.record("Could not find end of function body for \(name)")
        return ""
    }

    private static func stateDispatchWorkItemDeclarations(in source: String) -> [String] {
        let declarationBoundaryPrefixes = [
            "@",
            "private var ",
            "private let ",
            "var ",
            "let ",
            "static ",
            "func ",
            "}",
        ]
        var references: [String] = []
        var searchStart = source.startIndex
        while let stateRange = source.range(of: "@State", range: searchStart..<source.endIndex) {
            searchStart = stateRange.upperBound
            let searchEnd = source.endIndex
            guard source.range(of: "var ", range: stateRange.upperBound..<searchEnd) != nil else {
                continue
            }

            var declarationEnd = searchEnd
            var index = stateRange.upperBound
            while index < searchEnd {
                if source[index] == "\n" {
                    let nextLineStart = source.index(after: index)
                    let nextLineEnd = source[nextLineStart...].firstIndex(of: "\n") ?? source.endIndex
                    let nextLine = source[nextLineStart..<nextLineEnd].trimmingCharacters(in: .whitespaces)
                    if !nextLine.isEmpty,
                       declarationBoundaryPrefixes.contains(where: { nextLine.hasPrefix($0) }) {
                        declarationEnd = index
                        break
                    }
                } else if source[index] == ";" || source[index] == "{" {
                    declarationEnd = index
                    break
                }
                index = source.index(after: index)
            }

            let declaration = source[stateRange.lowerBound..<declarationEnd]
            guard declaration.contains("DispatchWorkItem") else { continue }
            references.append(lineReference(in: source, at: stateRange.lowerBound))
        }
        return references
    }

    private static func dispatchWorkItemClosuresWithoutCaptureList(in source: String) -> [String] {
        var references: [String] = []
        var searchStart = source.startIndex
        while let workItemRange = source.range(of: "DispatchWorkItem", range: searchStart..<source.endIndex) {
            searchStart = workItemRange.upperBound
            var next = workItemRange.upperBound
            while next < source.endIndex, source[next].isWhitespace {
                next = source.index(after: next)
            }

            let openingBrace: String.Index?
            if next < source.endIndex, source[next] == "{" {
                openingBrace = next
            } else if next < source.endIndex, source[next] == "(" {
                var depth = 0
                var index = next
                var closureBrace: String.Index?
                while index < source.endIndex {
                    switch source[index] {
                    case "(":
                        depth += 1
                    case ")":
                        depth -= 1
                        if depth == 0 {
                            index = source.endIndex
                            continue
                        }
                    case "{":
                        closureBrace = index
                        index = source.endIndex
                        continue
                    default:
                        break
                    }
                    if index < source.endIndex {
                        index = source.index(after: index)
                    }
                }
                openingBrace = closureBrace
            } else {
                continue
            }
            guard let openingBrace else { continue }

            var closureStart = source.index(after: openingBrace)
            while closureStart < source.endIndex, source[closureStart].isWhitespace {
                closureStart = source.index(after: closureStart)
            }
            if closureStart < source.endIndex, source[closureStart] == "[" {
                continue
            }
            references.append(lineReference(in: source, at: workItemRange.lowerBound))
        }
        return references
    }

    @Test
    func contentViewDoesNotChainQueuedDispatchWorkItemsThroughSwiftUIState() throws {
        let source = try Self.sourceText("Sources/ContentView.swift")

        let stateWorkItemLines = Self.stateDispatchWorkItemDeclarations(in: source)
        #expect(
            stateWorkItemLines.isEmpty,
            """
            ContentView must not keep DispatchWorkItems in SwiftUI @State. A queued \
            DispatchWorkItem closure that captures the ContentView value can retain the \
            previous @State work item, making replacement build an unbounded release chain:
            \(stateWorkItemLines.joined(separator: "\n"))
            """
        )

        let implicitSelfWorkItemLines = Self.dispatchWorkItemClosuresWithoutCaptureList(in: source)
        #expect(
            implicitSelfWorkItemLines.isEmpty,
            """
            ContentView DispatchWorkItem closures must use an explicit capture list or be \
            removed. The capture list may be formatted across lines, but implicit self \
            captures can retain the view's @State snapshot and link queued work items recursively:
            \(implicitSelfWorkItemLines.joined(separator: "\n"))
            """
        )

        let coalescedReplacementFunctions = [
            "scheduleSidebarResizerCursorRelease",
            "requestCommandPaletteFocusRestore",
        ]
        let functionsConstructingGCDWork = try coalescedReplacementFunctions.compactMap { name -> String? in
            let body = try Self.functionBody(named: name, in: source)
            guard body.contains("DispatchWorkItem")
                || body.contains("DispatchQueue.main.async")
                || body.contains("DispatchQueue.main.asyncAfter") else { return nil }
            return name
        }
        #expect(
            functionsConstructingGCDWork.isEmpty,
            """
            High-frequency ContentView replacement paths must use generation tokens or another \
            reference-free invalidation scheme instead of constructing GCD work:
            \(functionsConstructingGCDWork.joined(separator: "\n"))
            """
        )

        #expect(
            source.contains("scheduleSidebarResizerCursorRelease(delay: .milliseconds(50))"),
            """
            Sidebar resizer hover exit must keep a short deferred cursor-release window so \
            mouse-down and drag-start callbacks can establish resize state before the cursor \
            can be reset.
            """
        )
    }

    @Test
    @MainActor
    func commandPaletteFocusRestoreCoordinatorSupersedesOldTimeout() async {
        let clock = WorkspaceContentViewManualClock()
        let coordinator = CommandPaletteFocusRestoreCoordinator(
            timeout: .milliseconds(100),
            clock: clock
        )
        let firstTarget = Self.restoreFocusTarget()
        let secondTarget = Self.restoreFocusTarget()

        coordinator.request(target: firstTarget)
        await drainMainActorTasks()
        #expect(coordinator.pendingTarget?.workspaceId == firstTarget.workspaceId)

        clock.advance(by: .milliseconds(60))
        coordinator.request(target: secondTarget)
        await drainMainActorTasks()
        #expect(coordinator.pendingTarget?.workspaceId == secondTarget.workspaceId)

        clock.advance(by: .milliseconds(40))
        await drainMainActorTasks()
        #expect(
            coordinator.pendingTarget?.workspaceId == secondTarget.workspaceId,
            "The first request's cancelled timeout must not clear the newer pending target."
        )

        clock.advance(by: .milliseconds(60))
        await drainMainActorTasks()
        #expect(coordinator.pendingTarget?.workspaceId == nil)
    }

    @Test
    @MainActor
    func commandPaletteFocusRestoreCoordinatorClearCancelsTimeout() async {
        let clock = WorkspaceContentViewManualClock()
        let coordinator = CommandPaletteFocusRestoreCoordinator(
            timeout: .milliseconds(100),
            clock: clock
        )
        let target = Self.restoreFocusTarget()

        coordinator.request(target: target)
        await drainMainActorTasks()
        #expect(coordinator.pendingTarget?.workspaceId == target.workspaceId)

        coordinator.clear()
        #expect(coordinator.pendingTarget?.workspaceId == nil)

        clock.advance(by: .milliseconds(100))
        await drainMainActorTasks()
        #expect(coordinator.pendingTarget?.workspaceId == nil)
    }

    @Test
    @MainActor
    func testMinimalModeToggleDoesNotReevaluateChromeHeavyBodies() async throws {
        _ = NSApplication.shared

        let suiteName = "WorkspaceContentViewVisibilityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(
            WorkspacePresentationModeSettings.Mode.standard.rawValue,
            forKey: WorkspacePresentationModeSettings.modeKey
        )

        let tabManager = TabManager()
        for _ in 0..<6 {
            tabManager.addWorkspace(autoWelcomeIfNeeded: false)
        }
        let notificationStore = TerminalNotificationStore.shared
        let counts = MinimalModeBodyProbeCounts()
        let root = ContentView(updateViewModel: UpdateStateModel(), windowId: UUID())
            .environmentObject(tabManager)
            .environmentObject(notificationStore)
            .environmentObject(notificationStore.sidebarUnread)
            .environmentObject(SidebarState())
            .environmentObject(SidebarSelectionState())
            .environmentObject(FileExplorerState())
            .environmentObject(CmuxConfigStore())
            .environment(
                \.minimalModeInvalidationProbe,
                MinimalModeInvalidationProbe(
                    contentViewBody: { counts.contentViewBody += 1 },
                    workspaceContentBody: { counts.workspaceContentBody += 1 },
                    verticalTabsSidebarBody: { counts.verticalTabsSidebarBody += 1 }
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

        await Self.drainMainRunLoop(for: window)
        #expect(counts.contentViewBody > 0)
        #expect(counts.workspaceContentBody > 0)
        #expect(counts.verticalTabsSidebarBody > 0)

        counts.reset()
        defaults.set(
            WorkspacePresentationModeSettings.Mode.minimal.rawValue,
            forKey: WorkspacePresentationModeSettings.modeKey
        )
        await Self.drainMainRunLoop(for: window)

        #expect(
            counts.contentViewBody == 0,
            "Minimal-mode toggles must not re-evaluate the whole ContentView body."
        )
        #expect(
            counts.workspaceContentBody == 0,
            "Minimal-mode toggles must not re-evaluate WorkspaceContentView/Bonsplit content."
        )
        #expect(
            counts.verticalTabsSidebarBody == 0,
            "Minimal-mode toggles must not rebuild the vertical sidebar render context."
        )
    }

    @MainActor
    private static func drainMainRunLoop(for window: NSWindow, iterations: Int = 20) async {
        for _ in 0..<iterations {
            window.contentView?.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            await Task.yield()
        }
    }

    @Test
    func testNonSelectedNonRetiringWorkspaceIsFullyHidden() {
        #expect(
            MountedWorkspacePresentation.resolve(
                isSelectedWorkspace: false,
                isRetiringWorkspace: false
            ) ==
            MountedWorkspacePresentation(
                isRenderedVisible: false,
                isPanelVisible: false,
                renderOpacity: 0
            )
        )
    }

    @Test
    func testRetiringWorkspaceStaysPanelVisibleDuringHandoff() {
        #expect(
            MountedWorkspacePresentation.resolve(
                isSelectedWorkspace: false,
                isRetiringWorkspace: true
            ) ==
            MountedWorkspacePresentation(
                isRenderedVisible: true,
                isPanelVisible: true,
                renderOpacity: 1
            )
        )
    }

    @Test
    func testPanelVisibleInUIReturnsFalseWhenWorkspaceHidden() {
        #expect(
            !WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: false,
                paneHasSelectedTab: true,
                isSelectedInPane: true,
                isFocused: true
            )
        )
    }

    @Test
    func testPanelVisibleInUIReturnsTrueForSelectedPanel() {
        #expect(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                paneHasSelectedTab: true,
                isSelectedInPane: true,
                isFocused: false
            )
        )
    }

    @Test
    func testPanelVisibleInUIReturnsTrueForFocusedPanelDuringTransientSelectionGap() {
        #expect(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                paneHasSelectedTab: false,
                isSelectedInPane: false,
                isFocused: true
            )
        )
    }

    @Test
    func testPanelVisibleInUIReturnsFalseForStaleFocusedPanelWhenAnotherTabIsSelected() {
        #expect(
            !WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                paneHasSelectedTab: true,
                isSelectedInPane: false,
                isFocused: true
            )
        )
    }

    @Test
    func testPanelVisibleInUIReturnsFalseWhenNeitherSelectedNorFocused() {
        #expect(
            !WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                paneHasSelectedTab: false,
                isSelectedInPane: false,
                isFocused: false
            )
        )
    }

    @Test
    func testRenderedVisiblePanelPolicyPrefersSelectedTabOverStaleFocusedPanel() {
        let paneId = UUID()
        let selectedPanelId = UUID()
        let staleFocusedPanelId = UUID()

        #expect(
            WorkspacePanelVisibilityPolicy.visiblePanelIdForRenderedPane(
                paneId: paneId,
                selectedPanelId: selectedPanelId,
                firstPanelId: selectedPanelId,
                focusedPanelId: staleFocusedPanelId,
                focusedPanelPaneId: paneId
            ) == selectedPanelId
        )
    }

    @Test
    func testRenderedVisiblePanelPolicyFallsBackToFocusedPanelOnlyDuringSelectionGap() {
        let paneId = UUID()
        let focusedPanelId = UUID()

        #expect(
            WorkspacePanelVisibilityPolicy.visiblePanelIdForRenderedPane(
                paneId: paneId,
                selectedPanelId: nil,
                firstPanelId: UUID(),
                focusedPanelId: focusedPanelId,
                focusedPanelPaneId: paneId
            ) == focusedPanelId
        )
    }

    @Test
    func testTmuxWorkspacePaneOverlayRectReturnsMatchingPaneFrame() {
        let paneID = PaneID(id: UUID())
        let snapshot = LayoutSnapshot(
            containerFrame: PixelRect(x: 200, y: 32, width: 1200, height: 800),
            panes: [
                PaneGeometry(
                    paneId: paneID.id.uuidString,
                    frame: PixelRect(x: 877.5, y: 32, width: 500, height: 320),
                    selectedTabId: nil,
                    tabIds: []
                )
            ],
            focusedPaneId: paneID.id.uuidString,
            timestamp: 0
        )

        #expect(
            WorkspaceContentView.tmuxWorkspacePaneOverlayRect(
                layoutSnapshot: snapshot,
                paneId: paneID
            ) ==
            CGRect(x: 677.5, y: 28, width: 500, height: 292)
        )
    }

    @Test
    @MainActor
    func testTmuxWorkspacePaneUnreadRectsIncludeFocusedReadIndicator() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        let workspace = try #require(manager.selectedWorkspace, "Expected selected workspace geometry")
        let panelId = try #require(workspace.focusedPanelId, "Expected selected workspace geometry")
        let surfaceId = try #require(workspace.surfaceIdFromPanelId(panelId), "Expected selected workspace geometry")
        let paneId = try #require(workspace.paneId(forPanelId: panelId), "Expected selected workspace geometry")

        store.setFocusedReadIndicator(forTabId: workspace.id, surfaceId: panelId)

        let snapshot = LayoutSnapshot(
            containerFrame: PixelRect(x: 200, y: 32, width: 1200, height: 800),
            panes: [
                PaneGeometry(
                    paneId: paneId.id.uuidString,
                    frame: PixelRect(x: 877.5, y: 32, width: 500, height: 320),
                    selectedTabId: surfaceId.uuid.uuidString,
                    tabIds: [surfaceId.uuid.uuidString]
                )
            ],
            focusedPaneId: paneId.id.uuidString,
            timestamp: 0
        )

        #expect(
            WorkspaceContentView.tmuxWorkspacePaneUnreadRects(
                workspace: workspace,
                notificationStore: store,
                layoutSnapshot: snapshot
            ) ==
            [CGRect(x: 677.5, y: 28, width: 500, height: 292)]
        )
    }
}
