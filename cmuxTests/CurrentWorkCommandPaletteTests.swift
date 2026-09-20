import CmuxCommandPalette
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
        #expect(!(CurrentWorkPalettePresentation.matches(item: item, projection: observed, current: rebound)))
    }

    @Test
    func testResourceAndPanelStayExactAcrossAWorkspaceMove() {
        let item = fixture()
        let observed = item.projections[0]
        let current = SurfaceProjection(
            resource: SurfaceResourceID(machine: .cloud("test-machine"), kind: .terminal, key: "term_test"),
            workspaceID: UUID(), panelID: observed.panelID
        )
        #expect(CurrentWorkPalettePresentation.matches(item: item, projection: observed, current: current))
        var unrelatedPanel = current
        unrelatedPanel.panelID = UUID()
        #expect(!(CurrentWorkPalettePresentation.matches(item: item, projection: observed, current: unrelatedPanel)))
        var inconsistentProjection = observed
        inconsistentProjection.resourceRef = "test-machine/terminal/term_other"
        #expect(!(CurrentWorkPalettePresentation.matches(item: item, projection: inconsistentProjection, current: current)))
    }

    @Test
    func testUnprojectedAndStaleCloudWorkIsHonestInTheReadOnlyRow() {
        var item = fixture()
        item.projections = []
        item.freshness.state = "stale"
        let subtitle = CurrentWorkPalettePresentation.subtitle(item: item, canFocus: false)
        #expect(subtitle.contains(String(localized: "commandPalette.currentWork.notOpen", defaultValue: "No open local view · read only")))
        #expect(subtitle.contains(String(localized: "commandPalette.currentWork.notCurrent", defaultValue: "May be out of date")))
        #expect(subtitle.contains(item.placement.machine))
    }

    @Test
    func testCurrentProjectedWorkDoesNotClaimUnavailableOrStale() {
        let subtitle = CurrentWorkPalettePresentation.subtitle(item: fixture(), canFocus: true)
        #expect(!(subtitle.contains(String(localized: "commandPalette.currentWork.notOpen", defaultValue: "No open local view · read only"))))
        #expect(!(subtitle.contains(String(localized: "commandPalette.currentWork.notCurrent", defaultValue: "May be out of date"))))
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
}
