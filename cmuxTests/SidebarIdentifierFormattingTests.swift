import AppKit
import SwiftUI
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class SidebarIdentifierFormattingTests: XCTestCase {
    func testSidebarLabelsRenderPortAndPullRequestIdentifiersWithoutThousandsSeparators() throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }

        let strings = renderedStrings(in: harness.window.contentView)

        XCTAssertTrue(
            strings.contains(":2014"),
            "Expected sidebar port label without locale separators. Rendered strings: \(strings)"
        )
        XCTAssertTrue(
            strings.contains("PR #1234"),
            "Expected sidebar PR label without locale separators. Rendered strings: \(strings)"
        )
        XCTAssertFalse(
            strings.contains(":2,014"),
            "Sidebar should not locale-format port identifiers. Rendered strings: \(strings)"
        )
        XCTAssertFalse(
            strings.contains("PR #1,234"),
            "Sidebar should not locale-format pull request identifiers. Rendered strings: \(strings)"
        )
    }

    func testSidebarTooltipsRenderPortAndPullRequestIdentifiersWithoutThousandsSeparators() throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }

        let tooltips = renderedTooltips(in: harness.window.contentView)

        XCTAssertTrue(
            tooltips.contains("Open localhost:2014"),
            "Expected port tooltip without locale separators. Tooltips: \(tooltips)"
        )
        XCTAssertTrue(
            tooltips.contains("Open PR #1234"),
            "Expected PR tooltip without locale separators. Tooltips: \(tooltips)"
        )
        XCTAssertFalse(
            tooltips.contains("Open localhost:2,014"),
            "Sidebar should not locale-format port tooltips. Tooltips: \(tooltips)"
        )
        XCTAssertFalse(
            tooltips.contains("Open PR #1,234"),
            "Sidebar should not locale-format PR tooltips. Tooltips: \(tooltips)"
        )
    }

    func testWorkspaceRowTooltipUsesWorkspaceTitle() throws {
        let workspaceTitle = "Tooltip Workspace"
        let harness = try makeHarness(workspaceTitle: workspaceTitle)
        defer { harness.tearDown() }

        let tooltips = renderedTooltips(in: harness.window.contentView)

        XCTAssertTrue(
            tooltips.contains(workspaceTitle),
            "Expected workspace row tooltip to use the workspace title. Tooltips: \(tooltips)"
        )
    }

    private func makeHarness(workspaceTitle: String? = nil) throws -> SidebarHarness {
        _ = NSApplication.shared

        let defaults = UserDefaults.standard
        let trackedDefaults = [
            SidebarWorkspaceDetailSettings.hideAllDetailsKey,
            "sidebarShowPullRequest",
            "sidebarShowPorts",
        ]
        let originalDefaults = trackedDefaults.reduce(into: [String: Any?]()) { result, key in
            result[key] = defaults.object(forKey: key)
        }

        defaults.set(false, forKey: SidebarWorkspaceDetailSettings.hideAllDetailsKey)
        defaults.set(true, forKey: "sidebarShowPullRequest")
        defaults.set(true, forKey: "sidebarShowPorts")

        let notificationStore = TerminalNotificationStore.shared
        notificationStore.replaceNotificationsForTesting([])

        let tabManager = TabManager()
        guard let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            throw HarnessError.missingWorkspace
        }
        if let workspaceTitle {
            tabManager.setCustomTitle(tabId: workspace.id, title: workspaceTitle)
        }

        let pullRequestURL = try XCTUnwrap(URL(string: "https://github.com/manaflow-ai/cmux/pull/1234"))
        let branch = "issue-2530-sidebar-thousands-separator"
        workspace.panelGitBranches[panelId] = SidebarGitBranchState(branch: branch, isDirty: false)
        workspace.panelPullRequests[panelId] = SidebarPullRequestState(
            number: 1234,
            label: "PR",
            url: pullRequestURL,
            status: .open,
            branch: branch
        )
        workspace.listeningPorts = [2014]

        var selection: SidebarSelection = .tabs
        var selectedTabIds: Set<UUID> = [workspace.id]
        var lastSidebarSelectionIndex: Int? = 0

        let root = VerticalTabsSidebar(
            updateViewModel: UpdateViewModel(),
            fileExplorerState: FileExplorerState(),
            onSendFeedback: {},
            titlebarHeight: 0,
            selection: Binding(
                get: { selection },
                set: { selection = $0 }
            ),
            selectedTabIds: Binding(
                get: { selectedTabIds },
                set: { selectedTabIds = $0 }
            ),
            lastSidebarSelectionIndex: Binding(
                get: { lastSidebarSelectionIndex },
                set: { lastSidebarSelectionIndex = $0 }
            )
        )
        .environmentObject(tabManager)
        .environmentObject(notificationStore)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = MainWindowHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()

        return SidebarHarness(
            window: window,
            originalDefaults: originalDefaults
        )
    }

    private func renderedStrings(in root: NSView?) -> [String] {
        let strings = flattenedViews(from: root).flatMap { view -> [String] in
            var values: [String] = []
            if let textField = view as? NSTextField {
                let string = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !string.isEmpty {
                    values.append(string)
                }
            }
            if let button = view as? NSButton {
                let title = button.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    values.append(title)
                }
            }
            return values
        }
        return Array(Set(strings)).sorted()
    }

    private func renderedTooltips(in root: NSView?) -> [String] {
        let tooltips = flattenedViews(from: root).compactMap { view in
            guard let tooltip = view.toolTip?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !tooltip.isEmpty else { return nil }
            return tooltip
        }
        return Array(Set(tooltips)).sorted()
    }

    private func flattenedViews(from root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap(flattenedViews)
    }
}

private struct SidebarHarness {
    let window: NSWindow
    let originalDefaults: [String: Any?]

    func tearDown() {
        let defaults = UserDefaults.standard
        for (key, value) in originalDefaults {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        TerminalNotificationStore.shared.replaceNotificationsForTesting([])
        TerminalNotificationStore.shared.resetNotificationDeliveryHandlerForTesting()
        window.orderOut(nil)
    }
}

private enum HarnessError: Error {
    case missingWorkspace
}
