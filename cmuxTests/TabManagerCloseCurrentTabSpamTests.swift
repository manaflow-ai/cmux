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
final class TabManagerCloseCurrentTabSpamTests: XCTestCase {
    func testCloseCurrentTabSpamWithConfirmationEnabledPromptsOnceAndClosesOneWorkspace() {
        let manager = TabManager()
        while manager.tabs.count < 6 {
            _ = manager.addWorkspace()
        }

        for workspace in manager.tabs {
            guard let panelId = workspace.focusedPanelId,
                  let terminalPanel = workspace.terminalPanel(for: panelId) else {
                XCTFail("Expected each workspace to have a focused terminal panel")
                return
            }
            terminalPanel.surface.setNeedsConfirmCloseOverrideForTesting(true)
        }

        var prompts: [(title: String, message: String, acceptCmdD: Bool)] = []
        manager.confirmCloseHandler = { title, message, acceptCmdD in
            prompts.append((title, message, acceptCmdD))
            return true
        }

        for _ in 0..<5 {
            manager.closeCurrentTabWithConfirmation()
        }

        XCTAssertEqual(prompts.count, 1, "Expected close-tab spam to surface only one confirmation prompt")
        XCTAssertEqual(
            prompts.first?.title,
            String(localized: "dialog.closeWorkspace.title", defaultValue: "Close workspace?")
        )
        XCTAssertEqual(prompts.first?.acceptCmdD, false)
        XCTAssertEqual(manager.tabs.count, 5, "Expected only one workspace to close after the first accepted confirmation")
    }

    func testCloseWorkspaceEnqueuesTerminalRuntimeTeardownOffMainThread() {
        let manager = TabManager()
        let workspace = manager.addWorkspace()
        manager.selectWorkspace(workspace)

        guard let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            XCTFail("Expected focused terminal panel")
            return
        }

        let fakeSurface: ghostty_surface_t = UnsafeMutableRawPointer(bitPattern: 0x5282)!
        terminalPanel.surface.installRuntimeSurfaceForTesting(fakeSurface)
        terminalPanel.surface.setNeedsConfirmCloseOverrideForTesting(true)

        let nativeFreeStarted = expectation(description: "native free started")
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { _ in
            XCTAssertFalse(Thread.isMainThread, "Native surface free must not run on the main thread")
            nativeFreeStarted.fulfill()
        }
        defer {
            TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil
        }

        manager.confirmCloseHandler = { _, _, _ in true }

        XCTAssertTrue(manager.closeWorkspaceWithConfirmation(workspace))
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertFalse(manager.tabs.contains(where: { $0.id == workspace.id }))
        XCTAssertNil(terminalPanel.surface.surface)

        wait(for: [nativeFreeStarted], timeout: 3.0)
    }

    func testCloseCurrentTabSpamWithConfirmationDisabledClosesEveryRequestedWorkspace() {
        let manager = TabManager()
        while manager.tabs.count < 6 {
            _ = manager.addWorkspace()
        }

        for workspace in manager.tabs {
            guard let panelId = workspace.focusedPanelId,
                  let terminalPanel = workspace.terminalPanel(for: panelId) else {
                XCTFail("Expected each workspace to have a focused terminal panel")
                return
            }
            terminalPanel.surface.setNeedsConfirmCloseOverrideForTesting(false)
        }

        var promptCount = 0
        manager.confirmCloseHandler = { _, _, _ in
            promptCount += 1
            return true
        }

        for _ in 0..<5 {
            manager.closeCurrentTabWithConfirmation()
        }

        XCTAssertEqual(promptCount, 0, "Expected warning-disabled close-tab spam to bypass confirmation entirely")
        XCTAssertEqual(manager.tabs.count, 1, "Expected warning-disabled close-tab spam to close all requested workspaces")
    }
}


