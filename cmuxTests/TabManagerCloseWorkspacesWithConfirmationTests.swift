import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import CmuxGit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


@MainActor
final class TabManagerCloseWorkspacesWithConfirmationTests: XCTestCase {
    func testCloseWorkspacesWithConfirmationPromptsOnceAndClosesAcceptedWorkspaces() {
        let manager = TabManager()
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.setCustomTitle(tabId: manager.tabs[0].id, title: "Alpha")
        manager.setCustomTitle(tabId: second.id, title: "Beta")
        manager.setCustomTitle(tabId: third.id, title: "Gamma")

        var prompts: [(title: String, message: String, acceptCmdD: Bool)] = []
        manager.confirmCloseHandler = { title, message, acceptCmdD in
            prompts.append((title, message, acceptCmdD))
            return true
        }

        manager.closeWorkspacesWithConfirmation([manager.tabs[0].id, second.id], allowPinned: true)

        let expectedMessage = String(
            format: String(
                localized: "dialog.closeWorkspaces.message",
                defaultValue: "This will close %1$lld workspaces and all of their panels:\n%2$@"
            ),
            locale: .current,
            Int64(2),
            "• Alpha\n• Beta"
        )
        XCTAssertEqual(prompts.count, 1, "Expected a single confirmation prompt for multi-close")
        XCTAssertEqual(
            prompts.first?.title,
            String(localized: "dialog.closeWorkspaces.title", defaultValue: "Close workspaces?")
        )
        XCTAssertEqual(prompts.first?.message, expectedMessage)
        XCTAssertEqual(prompts.first?.acceptCmdD, false)
        XCTAssertEqual(manager.tabs.map(\.title), ["Gamma"])
    }

    func testCloseWorkspacesWithConfirmationKeepsWorkspacesWhenCancelled() {
        let manager = TabManager()
        let second = manager.addWorkspace()
        manager.setCustomTitle(tabId: manager.tabs[0].id, title: "Alpha")
        manager.setCustomTitle(tabId: second.id, title: "Beta")

        var prompts: [(title: String, message: String, acceptCmdD: Bool)] = []
        manager.confirmCloseHandler = { title, message, acceptCmdD in
            prompts.append((title, message, acceptCmdD))
            return false
        }

        manager.closeWorkspacesWithConfirmation([manager.tabs[0].id, second.id], allowPinned: true)

        let expectedMessage = String(
            format: String(
                localized: "dialog.closeWorkspacesWindow.message",
                defaultValue: "This will close the current window, its %1$lld workspaces, and all of their panels:\n%2$@"
            ),
            locale: .current,
            Int64(2),
            "• Alpha\n• Beta"
        )
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(
            prompts.first?.title,
            String(localized: "dialog.closeWindow.title", defaultValue: "Close window?")
        )
        XCTAssertEqual(prompts.first?.message, expectedMessage)
        XCTAssertEqual(prompts.first?.acceptCmdD, true)
        XCTAssertEqual(manager.tabs.map(\.title), ["Alpha", "Beta"])
    }

    func testCloseWorkspacesWithConfirmationHonorsWarnBeforeClosingTabDisabled() {
        let defaults = UserDefaults.standard
        let originalWarnBeforeClosingTab = defaults.object(forKey: CloseTabWarningSettings.warnBeforeClosingTabKey)
        defaults.set(false, forKey: CloseTabWarningSettings.warnBeforeClosingTabKey)
        defer {
            if let originalWarnBeforeClosingTab {
                defaults.set(originalWarnBeforeClosingTab, forKey: CloseTabWarningSettings.warnBeforeClosingTabKey)
            } else {
                defaults.removeObject(forKey: CloseTabWarningSettings.warnBeforeClosingTabKey)
            }
        }

        let manager = TabManager()
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.setCustomTitle(tabId: manager.tabs[0].id, title: "Alpha")
        manager.setCustomTitle(tabId: second.id, title: "Beta")
        manager.setCustomTitle(tabId: third.id, title: "Gamma")

        var promptCount = 0
        manager.confirmCloseHandler = { _, _, _ in
            promptCount += 1
            return false
        }

        manager.closeWorkspacesWithConfirmation([manager.tabs[0].id, second.id], allowPinned: true)

        XCTAssertEqual(promptCount, 0)
        XCTAssertEqual(manager.tabs.map(\.title), ["Gamma"])
    }

    func testCloseCurrentWorkspaceWithConfirmationUsesSidebarMultiSelection() {
        let manager = TabManager()
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.setCustomTitle(tabId: manager.tabs[0].id, title: "Alpha")
        manager.setCustomTitle(tabId: second.id, title: "Beta")
        manager.setCustomTitle(tabId: third.id, title: "Gamma")
        manager.selectWorkspace(second)
        manager.setSidebarSelectedWorkspaceIds([manager.tabs[0].id, second.id])

        var prompts: [(title: String, message: String, acceptCmdD: Bool)] = []
        manager.confirmCloseHandler = { title, message, acceptCmdD in
            prompts.append((title, message, acceptCmdD))
            return false
        }

        manager.closeCurrentWorkspaceWithConfirmation()

        let expectedMessage = String(
            format: String(
                localized: "dialog.closeWorkspaces.message",
                defaultValue: "This will close %1$lld workspaces and all of their panels:\n%2$@"
            ),
            locale: .current,
            Int64(2),
            "• Alpha\n• Beta"
        )
        XCTAssertEqual(prompts.count, 1, "Expected Cmd+Shift+W path to reuse the multi-close summary dialog")
        XCTAssertEqual(
            prompts.first?.title,
            String(localized: "dialog.closeWorkspaces.title", defaultValue: "Close workspaces?")
        )
        XCTAssertEqual(prompts.first?.message, expectedMessage)
        XCTAssertEqual(prompts.first?.acceptCmdD, false)
        XCTAssertEqual(manager.tabs.map(\.title), ["Alpha", "Beta", "Gamma"])
    }
}

