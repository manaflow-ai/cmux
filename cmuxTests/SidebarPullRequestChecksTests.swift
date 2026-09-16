import Foundation
import Testing
import CmuxSettings
import CmuxSidebar
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct SidebarPullRequestChecksTests {
    @Test func blockedMergeDoesNotHidePendingOrFailedChecks() {
        for (state, icon) in [(SidebarPullRequestCheckStatus.pending, "clock"), (.failure, "xmark")] {
            let display = SidebarPullRequestChecksDisplay(checks: SidebarPullRequestChecks(
                status: state, checks: [], mergeStatus: .blocked
            ))
            #expect(display.iconName == icon)
            #expect(display.tooltip.contains(display.statusLabel))
            #expect(display.tooltip.contains(display.mergeLabel))
        }
    }

    @Test func conflictsAreDistinctFromSuccessfulChecks() {
        let display = SidebarPullRequestChecksDisplay(checks: SidebarPullRequestChecks(
            status: .success, checks: [], mergeStatus: .conflict
        ))
        #expect(display.iconName == "exclamationmark.triangle.fill")
        #expect(display.tooltip.contains(display.mergeLabel))
        #expect(display.tooltip.contains(display.statusLabel))
    }

    @Test func tooltipKeepsFailuresVisibleInLargeSuites() {
        let checks = (0..<30).map { SidebarPullRequestCheck(id: String($0), name: "Passed \($0)", status: .success) }
            + [SidebarPullRequestCheck(id: "failure", name: "Critical integration", status: .failure)]
        let display = SidebarPullRequestChecksDisplay(checks: SidebarPullRequestChecks(
            status: .failure, checks: checks, mergeStatus: .blocked
        ))
        let lines = display.tooltip.components(separatedBy: "\n")
        #expect(lines[2] == "× Critical integration")
        #expect(lines.count == 23)
    }

    @Test func unavailableIsDistinctFromAnEmptyCheckList() {
        let missing = SidebarPullRequestChecksDisplay(checks: SidebarPullRequestChecks(
            status: .unavailable, checks: [], mergeStatus: .unknown
        ))
        let empty = SidebarPullRequestChecksDisplay(checks: SidebarPullRequestChecks(
            status: .neutral, checks: [], mergeStatus: .ready
        ))
        #expect(missing.iconName != empty.iconName)
        #expect(missing.statusLabel != empty.statusLabel)
    }

    @Test func optInIsSharedByBothSidebarRenderers() throws {
        let suite = "pr-checks-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!SidebarTabItemSettingsSnapshot(defaults: defaults).showsPullRequestChecks)
        let client = UserDefaultsSettingsClient(defaults: defaults)
        client.set(true, for: SidebarCatalogSection().showPullRequestChecks)
        let enabled = SidebarTabItemSettingsSnapshot(defaults: defaults)
        #expect(enabled.showsPullRequestChecks)
        #expect(enabled.details.showPullRequestChecks)
    }
}
