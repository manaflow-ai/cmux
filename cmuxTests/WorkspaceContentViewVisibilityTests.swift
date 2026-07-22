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
        var references: [String] = []
        var searchStart = source.startIndex
        while let stateRange = source.range(of: "@State", range: searchStart..<source.endIndex) {
            searchStart = stateRange.upperBound
            var sawPropertyDeclaration = Self.lineStartsVarDeclaration(
                source[
                    stateRange.lowerBound..<(source[stateRange.lowerBound...].firstIndex(of: "\n") ?? source.endIndex)
                ]
                .trimmingCharacters(in: .whitespaces)
            )
            var declarationEnd = source.endIndex
            var lineEnd = source[stateRange.upperBound...].firstIndex(of: "\n") ?? source.endIndex

            while lineEnd < source.endIndex {
                let nextLineStart = source.index(after: lineEnd)
                let nextLineEnd = source[nextLineStart...].firstIndex(of: "\n") ?? source.endIndex
                let nextLine = source[nextLineStart..<nextLineEnd].trimmingCharacters(in: .whitespaces)
                if !nextLine.isEmpty {
                    if sawPropertyDeclaration, Self.lineStartsDeclarationBoundary(nextLine) {
                        declarationEnd = lineEnd
                        break
                    }
                    if !sawPropertyDeclaration,
                       Self.lineStartsDeclarationBoundary(nextLine),
                       !nextLine.hasPrefix("@"),
                       !Self.lineStartsVarDeclaration(nextLine) {
                        declarationEnd = lineEnd
                        break
                    }
                    sawPropertyDeclaration = sawPropertyDeclaration || Self.lineStartsVarDeclaration(nextLine)
                    if nextLine.contains(";") || nextLine.contains("{") {
                        declarationEnd = nextLineEnd
                        break
                    }
                }
                lineEnd = nextLineEnd
            }
            if declarationEnd == source.endIndex {
                declarationEnd = lineEnd
            }
            let declaration = source[stateRange.lowerBound..<declarationEnd]
            guard sawPropertyDeclaration, declaration.contains("DispatchWorkItem") else { continue }
            references.append(lineReference(in: source, at: stateRange.lowerBound))
        }
        return references
    }

    private static func lineStartsVarDeclaration(_ line: some StringProtocol) -> Bool {
        var text = String(line).trimmingCharacters(in: .whitespaces)
        while text.hasPrefix("@") {
            guard let attributeEnd = text.firstIndex(where: { $0.isWhitespace }) else { return false }
            text = text[attributeEnd...].trimmingCharacters(in: .whitespaces)
        }
        return text.hasPrefix("var ")
            || text.hasPrefix("private var ")
            || text.hasPrefix("fileprivate var ")
            || text.hasPrefix("internal var ")
    }

    private static func lineStartsDeclarationBoundary(_ line: some StringProtocol) -> Bool {
        line.hasPrefix("@")
            || lineStartsVarDeclaration(line)
            || line.hasPrefix("let ")
            || line.hasPrefix("private let ")
            || line.hasPrefix("fileprivate let ")
            || line.hasPrefix("internal let ")
            || line.hasPrefix("static ")
            || line.hasPrefix("func ")
            || line.hasPrefix("private func ")
            || line.hasPrefix("}")
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
                var afterArguments: String.Index?
                while index < source.endIndex {
                    switch source[index] {
                    case "(":
                        depth += 1
                    case ")":
                        depth -= 1
                        if depth == 0 {
                            afterArguments = source.index(after: index)
                            index = source.endIndex
                            continue
                        }
                    default:
                        break
                    }
                    if index < source.endIndex {
                        index = source.index(after: index)
                    }
                }
                var brace = afterArguments
                while let candidate = brace, candidate < source.endIndex, source[candidate].isWhitespace {
                    brace = source.index(after: candidate)
                }
                if let candidate = brace, candidate < source.endIndex, source[candidate] == "{" {
                    openingBrace = candidate
                } else {
                    openingBrace = nil
                }
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
    func dispatchWorkItemRegressionScannerCatchesSplitDeclarationsAndTrailingClosures() {
        let source = """
        struct ContentView {
            @State
            private var splitWorkItem:
                DispatchWorkItem?
            @State private var inlineWorkItem: DispatchWorkItem?

            private func scheduleWork() {
                let unsafe = DispatchWorkItem(qos: .userInteractive) {
                    _ = self
                }
                let safe = DispatchWorkItem(qos: .userInteractive) { [weak self] in
                    _ = self
                }
                _ = (unsafe, safe)
            }
        }
        """

        #expect(Self.stateDispatchWorkItemDeclarations(in: source).count == 2)
        #expect(Self.dispatchWorkItemClosuresWithoutCaptureList(in: source).count == 1)
    }

    @Test
    func commandPaletteFocusRestoreClearsUnresolvableTargetsWithoutTimedTasks() throws {
        let contentViewSource = try Self.sourceText("Sources/ContentView.swift")
        let restoreBody = try Self.functionBody(named: "attemptCommandPaletteFocusRestoreIfNeeded", in: contentViewSource)
        #expect(
            restoreBody.contains(
                "guard targetWorkspace.panels[target.panelId] != nil else {\n            commandPaletteFocusRestoreCoordinator.clear()"
            )
        )
        #expect(
            restoreBody.contains(
                "guard context.panel.restoreFocusIntent(target.intent) else {\n            commandPaletteFocusRestoreCoordinator.clear()"
            )
        )

        let coordinatorSource = try Self.sourceText("Sources/CommandPaletteFocusRestoreCoordinator.swift")
        #expect(!coordinatorSource.contains("Task"))
        #expect(!coordinatorSource.contains("sleep"))
    }

    @Test
    @MainActor
    func commandPaletteFocusRestoreCoordinatorKeepsLatestTargetUntilExplicitClear() {
        let coordinator = CommandPaletteFocusRestoreCoordinator()
        let firstTarget = Self.restoreFocusTarget()
        let secondTarget = Self.restoreFocusTarget()

        coordinator.request(target: firstTarget)
        #expect(coordinator.pendingTarget?.workspaceId == firstTarget.workspaceId)

        coordinator.request(target: secondTarget)
        #expect(coordinator.pendingTarget?.workspaceId == secondTarget.workspaceId)

        coordinator.clear()
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
