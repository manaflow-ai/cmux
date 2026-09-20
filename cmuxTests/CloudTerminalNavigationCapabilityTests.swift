import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct CloudTerminalNavigationCapabilityTests {
    @Test("Existing projection wins over a supplied destination; fallback uses that destination", arguments: [false, true])
    func reusesExistingProjection(hasProjection: Bool) async {
        let fixture = CloudTerminalNavigationFixture()
        let supplied = UUID()
        fixture.existingWorkspaceID = hasProjection ? fixture.workspaceID : nil
        let navigation = fixture.makeNavigation()
        navigation.open(machine: fixture.machine, group: fixture.group, resource: fixture.resource, view: fixture.view, openIn: supplied)
        await fixture.wait()
        #expect(fixture.events == ["check", "lookup", "project", "focus"])
        #expect(fixture.projectedWorkspaceID == (hasProjection ? fixture.workspaceID : supplied))
        #expect(fixture.projectedView == fixture.view)
        #expect(fixture.focused.first?.0 == fixture.panelID)
        #expect(fixture.focused.first?.1 == fixture.workspaceID)
        #expect(fixture.failures.isEmpty)
    }

    @Test("Restore retains layout, owner identity, exact clicked tab and generated title")
    func restoresExactTab() async {
        let fixture = CloudTerminalNavigationFixture()
        var other = fixture.projection
        other.panelID = UUID()
        other.remoteTabID = "tab-other"
        fixture.restoredProjections = [other, fixture.projection]
        let navigation = fixture.makeNavigation()
        navigation.open(machine: fixture.machine, group: fixture.group, resource: fixture.resource, view: fixture.view, openIn: nil)
        await fixture.wait()
        #expect(fixture.events == ["check", "lookup", "layout", "check", "open", "bind", "focus"])
        #expect(fixture.receivedLayout == fixture.layout)
        #expect(fixture.receivedGroup == fixture.group)
        #expect(fixture.openedTitle == "Project")
        #expect(fixture.boundTitle == "Project")
        #expect(fixture.focused.count == 1)
        #expect(fixture.focused.first?.0 == fixture.panelID)
        #expect(fixture.failures.isEmpty)
    }

    @Test("Missing or ambiguous clicked projections close only the opened workspace and return one original error", arguments: 0..<4)
    func rejectsMissingOrAmbiguousProjection(variant: Int) async {
        let fixture = CloudTerminalNavigationFixture()
        var wrong = fixture.projection
        switch variant {
        case 0: wrong.remoteTabID = "different-tab"
        case 1: wrong.remoteWorkspaceID = "different-workspace"
        case 2: wrong.resource = SurfaceResourceID(machine: fixture.machine, kind: .terminal, key: "different-resource")
        default: break
        }
        fixture.restoredProjections = variant == 3 ? [wrong, wrong] : [wrong]
        let navigation = fixture.makeNavigation()
        navigation.open(machine: fixture.machine, group: fixture.group, resource: fixture.resource, view: fixture.view, openIn: nil)
        await fixture.wait()
        #expect(fixture.events == ["check", "lookup", "layout", "check", "open", "bind", "close"])
        #expect(fixture.closed == [fixture.workspaceID])
        #expect(fixture.focused.isEmpty)
        #expect(fixture.failures.count == 1)
        #expect(fixture.failures.first as? SurfaceCatalogError == .destinationNotFound(
            String(localized: "cloudTree.error.terminalRestoreFailed", defaultValue: "The clicked Cloud terminal could not be restored in its workspace.")
        ))
    }

    @Test("Deletion admission before or during layout fetch cancels without opening", arguments: [1, 2])
    func checksDeletionAcrossSuspension(check: Int) async {
        let fixture = CloudTerminalNavigationFixture()
        fixture.checkFailureAt = check == 1 ? 1 : nil
        fixture.delayLayout = check == 2
        let navigation = fixture.makeNavigation()
        navigation.open(machine: fixture.machine, group: fixture.group, resource: fixture.resource, view: fixture.view, openIn: nil)
        if check == 2 {
            for await _ in fixture.layoutStarted.stream { break }
            fixture.checkFailureAt = 2
            fixture.releaseLayout()
        }
        await fixture.wait()
        #expect(fixture.events == (check == 1 ? ["check"] : ["check", "lookup", "layout", "check"]))
        #expect(fixture.failures.count == 1)
        #expect(fixture.failures.first is CancellationError)
        #expect(fixture.closed.isEmpty)
        #expect(fixture.focused.isEmpty)
    }

    @Test("Cancellation after restore closes the opened workspace before binding")
    func cancelledRestoreClosesProjection() async {
        let fixture = CloudTerminalNavigationFixture()
        fixture.cancelAfterOpen = true
        let navigation = fixture.makeNavigation()
        navigation.open(machine: fixture.machine, group: fixture.group, resource: fixture.resource, view: fixture.view, openIn: nil)
        await fixture.wait()
        #expect(fixture.events == ["check", "lookup", "layout", "check", "open", "close"])
        #expect(fixture.closed == [fixture.workspaceID])
        #expect(fixture.failures.first is CancellationError)
        #expect(fixture.focused.isEmpty)
    }

    @Test("The operation owner can reject feature-disabled navigation without touching the catalog")
    func disabledFeatureDoesNotStart() async {
        let fixture = CloudTerminalNavigationFixture()
        fixture.available = false
        let navigation = fixture.makeNavigation()
        navigation.open(machine: fixture.machine, group: fixture.group, resource: fixture.resource, view: fixture.view, openIn: nil)
        await fixture.wait()
        #expect(fixture.events.isEmpty)
        #expect(fixture.failures.isEmpty)
    }

    @Test("A catalog failure is returned once with its original type", arguments: [false, true])
    func reportsFailureOnce(reuse: Bool) async {
        let fixture = CloudTerminalNavigationFixture()
        fixture.existingWorkspaceID = reuse ? fixture.workspaceID : nil
        fixture.failure = SurfaceCatalogError.unknownResource(fixture.resource)
        let navigation = fixture.makeNavigation()
        navigation.open(machine: fixture.machine, group: fixture.group, resource: fixture.resource, view: fixture.view, openIn: nil)
        await fixture.wait()
        #expect(fixture.failures.count == 1)
        #expect(fixture.failures.first as? SurfaceCatalogError == .unknownResource(fixture.resource))
        #expect(fixture.closed.isEmpty)
        #expect(fixture.focused.isEmpty)
    }
}
