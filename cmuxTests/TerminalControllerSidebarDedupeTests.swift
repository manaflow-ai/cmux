import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class TerminalControllerSidebarDedupeTests: XCTestCase {
    func testShouldReplaceStatusEntryReturnsFalseForUnchangedPayload() {
        let current = SidebarStatusEntry(
            key: "agent",
            value: "idle",
            icon: "bolt",
            color: "#ffffff",
            timestamp: Date(timeIntervalSince1970: 123)
        )
        XCTAssertFalse(
            TerminalController.shouldReplaceStatusEntry(
                current: current,
                key: "agent",
                value: "idle",
                icon: "bolt",
                color: "#ffffff",
                url: nil,
                priority: 0,
                format: .plain
            )
        )
    }

    func testShouldReplaceStatusEntryReturnsTrueWhenValueChanges() {
        let current = SidebarStatusEntry(
            key: "agent",
            value: "idle",
            icon: "bolt",
            color: "#ffffff",
            timestamp: Date(timeIntervalSince1970: 123)
        )
        XCTAssertTrue(
            TerminalController.shouldReplaceStatusEntry(
                current: current,
                key: "agent",
                value: "running",
                icon: "bolt",
                color: "#ffffff",
                url: nil,
                priority: 0,
                format: .plain
            )
        )
    }

    func testShouldReplaceProgressReturnsFalseForUnchangedPayload() {
        XCTAssertFalse(
            TerminalController.shouldReplaceProgress(
                current: SidebarProgressState(value: 0.42, label: "indexing"),
                value: 0.42,
                label: "indexing"
            )
        )
    }

    func testShouldReplaceGitBranchReturnsFalseForUnchangedPayload() {
        XCTAssertFalse(
            TerminalController.shouldReplaceGitBranch(
                current: SidebarGitBranchState(branch: "main", isDirty: true),
                branch: "main",
                isDirty: true
            )
        )
    }

    func testShouldReplacePortsIgnoresOrderAndDuplicates() {
        XCTAssertFalse(
            TerminalController.shouldReplacePorts(
                current: [9229, 3000],
                next: [3000, 9229, 3000]
            )
        )
        XCTAssertTrue(
            TerminalController.shouldReplacePorts(
                current: [9229, 3000],
                next: [3000]
            )
        )
    }

    func testShouldReplacePullRequestReturnsTrueWhenCurrentStateIsStale() throws {
        let url = try XCTUnwrap(URL(string: "https://github.com/manaflow-ai/cmux/pull/42"))
        let current = SidebarPullRequestState(
            number: 42,
            label: "PR",
            url: url,
            status: .open,
            branch: "feature/work",
            isStale: true
        )

        XCTAssertTrue(
            TerminalController.shouldReplacePullRequest(
                current: current,
                number: 42,
                label: "PR",
                url: url,
                status: .open,
                branch: "feature/work"
            )
        )
    }

    func testExplicitSocketScopeParsesValidUUIDTabAndPanel() {
        let workspaceId = UUID()
        let panelId = UUID()
        let scope = TerminalController.explicitSocketScope(
            options: [
                "tab": workspaceId.uuidString,
                "panel": panelId.uuidString
            ]
        )
        XCTAssertEqual(scope?.workspaceId, workspaceId)
        XCTAssertEqual(scope?.panelId, panelId)
    }

    func testExplicitSocketScopeAcceptsSurfaceAlias() {
        let workspaceId = UUID()
        let panelId = UUID()
        let scope = TerminalController.explicitSocketScope(
            options: [
                "tab": workspaceId.uuidString,
                "surface": panelId.uuidString
            ]
        )
        XCTAssertEqual(scope?.workspaceId, workspaceId)
        XCTAssertEqual(scope?.panelId, panelId)
    }

    func testExplicitSocketScopeRejectsMissingOrInvalidValues() {
        XCTAssertNil(TerminalController.explicitSocketScope(options: [:]))
        XCTAssertNil(TerminalController.explicitSocketScope(options: ["tab": "workspace:1", "panel": UUID().uuidString]))
        XCTAssertNil(TerminalController.explicitSocketScope(options: ["tab": UUID().uuidString, "panel": "surface:1"]))
    }

    func testNormalizeReportedDirectoryTrimsWhitespace() {
        XCTAssertEqual(
            TerminalController.normalizeReportedDirectory("   /Users/cmux/project   "),
            "/Users/cmux/project"
        )
    }

    func testNormalizeReportedDirectoryResolvesFileURL() {
        XCTAssertEqual(
            TerminalController.normalizeReportedDirectory("file:///Users/cmux/project"),
            "/Users/cmux/project"
        )
    }

    func testNormalizeReportedDirectoryLeavesInvalidURLTrimmed() {
        XCTAssertEqual(
            TerminalController.normalizeReportedDirectory("  file://bad host  "),
            "file://bad host"
        )
    }
}
