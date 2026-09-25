import CmuxCloud
import CmuxCommandPalette
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
@MainActor
struct CurrentWorkCommandPaletteTests {
    @Test
    func testFindWorkKeepsPaletteOpenForTheSharedSnapshot() {
        let contribution = ContentView.commandPaletteFindWorkContribution()
        #expect(contribution.commandId == "palette.findWork")
        #expect(!(contribution.dismissOnRun))
        #expect(contribution.keywords.contains("attention"))
    }

    @Test
    func testObservedResourceCannotNavigateAReboundPanel() {
        let item = fixture()
        let observed = item.projections[0]
        let rebound = SurfaceProjection(
            resource: SurfaceResourceID(machine: .cloud("other-machine"), kind: .terminal, key: "term_other"),
            workspaceID: observed.workspaceID, panelID: observed.panelID
        )
        #expect(!(CurrentWorkPalettePresentation(item: item).matches(projection: observed, current: rebound)))
    }

    @Test
    func testResourceAndPanelStayExactAcrossAWorkspaceMove() {
        let item = fixture()
        let observed = item.projections[0]
        let current = SurfaceProjection(
            resource: SurfaceResourceID(machine: .cloud("test-machine"), kind: .terminal, key: "term_test"),
            workspaceID: UUID(), panelID: observed.panelID
        )
        #expect(CurrentWorkPalettePresentation(item: item).matches(projection: observed, current: current))
        var unrelatedPanel = current
        unrelatedPanel.panelID = UUID()
        #expect(!(CurrentWorkPalettePresentation(item: item).matches(projection: observed, current: unrelatedPanel)))
        var inconsistentProjection = observed
        inconsistentProjection.resourceRef = "test-machine/terminal/term_other"
        #expect(!(CurrentWorkPalettePresentation(item: item).matches(projection: inconsistentProjection, current: current)))
    }

    @Test
    func testUnprojectedAndStaleCloudWorkIsHonestInTheReadOnlyRow() {
        var item = fixture()
        item.projections = []
        item.freshness.state = "stale"
        let subtitle = CurrentWorkPalettePresentation(item: item).subtitle(canFocus: false)
        #expect(subtitle.contains(String(localized: "commandPalette.currentWork.notOpen", defaultValue: "No open local view · read only")))
        #expect(subtitle.contains(String(localized: "commandPalette.currentWork.notCurrent", defaultValue: "May be out of date")))
        #expect(subtitle.contains(item.placement.machine))
    }

    @Test
    func testCurrentProjectedWorkDoesNotClaimUnavailableOrStale() {
        let subtitle = CurrentWorkPalettePresentation(item: fixture()).subtitle(canFocus: true)
        #expect(!(subtitle.contains(String(localized: "commandPalette.currentWork.notOpen", defaultValue: "No open local view · read only"))))
        #expect(!(subtitle.contains(String(localized: "commandPalette.currentWork.notCurrent", defaultValue: "May be out of date"))))
    }

    @Test
    func testPullRequestSubtitleUsesTheLocalizedLabelFormat() {
        var item = fixture()
        item.pullRequests = [pullRequest(number: 123), pullRequest(number: 456)]

        let subtitle = CurrentWorkPalettePresentation(item: item).subtitle(canFocus: true)
        let format = String(localized: "cli.current.pullRequest", defaultValue: "PR: %@")
        let expected = [123, 456].map { format.replacingOccurrences(of: "%@", with: "#\($0)") }

        for label in expected {
            #expect(subtitle.contains(label))
        }
    }

    private func fixture() -> CurrentWorkSnapshot.Item {
        let resource = SurfaceResourceID(machine: .cloud("test-machine"), kind: .terminal, key: "term_test").rawValue
        return .init(
            resourceRef: resource, durableSurfaceID: nil, label: "Review", kind: "terminal", lifecycle: "running",
            placement: .init(kind: "cloud", machine: "test-machine"),
            projections: [.init(resourceRef: resource, workspaceID: UUID(), panelID: UUID(), stableSurfaceID: nil,
                                stableWorkspaceID: nil, remoteWorkspaceID: "ws_test", remoteTabID: "tab_test")],
            cwd: "/project", projectHints: [], repositoryHints: [], agents: [], attention: [], pullRequests: [],
            freshness: .init(state: "current", reason: nil, observedAt: "2026-09-20T00:00:00Z"),
            cursor: nil, receiptRefs: [], possibleHumanObligations: [], evidence: [], omitted: [:]
        )
    }

    private func pullRequest(number: Int) -> CurrentWorkSnapshot.PullRequest {
        let freshness = CurrentWorkSnapshot.Freshness(state: "current", reason: nil, observedAt: "2026-09-20T00:00:00Z")
        let evidence = CurrentWorkSnapshot.Evidence(owner: "test", reference: "fixture", observedAt: freshness.observedAt)
        return .init(
            number: number, url: "https://github.com/manaflow-ai/cmux/pull/\(number)", label: "#\(number)",
            status: "open", workspaceID: UUID(), freshness: freshness, evidence: evidence
        )
    }
}
