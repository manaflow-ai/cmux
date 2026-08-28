import CmuxControlSocket
import CmuxSidebar
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite("CustomSidebarWorkspaceFocusRouter")
@MainActor
struct CustomSidebarWorkspaceFocusRouterTests {
    private final class SelectRecorder {
        var routings: [ControlRoutingSelectors] = []
        var workspaceIDs: [UUID] = []
        var resolution: ControlWorkspaceRoutedResolution = .resolved(windowID: nil)
    }

    private func makeRouter(recorder: SelectRecorder) -> CustomSidebarWorkspaceFocusRouter {
        CustomSidebarWorkspaceFocusRouter { routing, workspaceID in
            recorder.routings.append(routing)
            recorder.workspaceIDs.append(workspaceID)
            return recorder.resolution
        }
    }

    // The sidebar's three statuses come straight off the shared select path's resolutions; a page
    // must be able to tell "gone" from "try again" and neither from success.
    @Test("a resolved selection reports focused")
    func resolvedMapsToFocused() {
        let recorder = SelectRecorder()
        recorder.resolution = .resolved(windowID: UUID())
        #expect(makeRouter(recorder: recorder).focus(UUID()) == .focused)
    }

    @Test("a selection resolved without an owning window still reports focused")
    func resolvedWithoutWindowMapsToFocused() {
        let recorder = SelectRecorder()
        recorder.resolution = .resolved(windowID: nil)
        #expect(makeRouter(recorder: recorder).focus(UUID()) == .focused)
    }

    @Test("a missing workspace reports not-found")
    func notFoundMapsToNotFound() {
        let recorder = SelectRecorder()
        recorder.resolution = .notFound
        #expect(makeRouter(recorder: recorder).focus(UUID()) == .notFound)
    }

    @Test("an unresolvable tab manager reports unavailable")
    func tabManagerUnavailableMapsToUnavailable() {
        let recorder = SelectRecorder()
        recorder.resolution = .tabManagerUnavailable
        #expect(makeRouter(recorder: recorder).focus(UUID()) == .unavailable)
    }

    // Routing by workspace id alone is what makes a click in one window's sidebar select and raise a
    // workspace living in another. Pinning the current window would silently scope the bridge to it.
    @Test("routing carries only the workspace id, so the owning window is discovered not assumed")
    func routesByWorkspaceIdentityOnly() throws {
        let recorder = SelectRecorder()
        let workspaceID = UUID()

        _ = makeRouter(recorder: recorder).focus(workspaceID)

        #expect(recorder.workspaceIDs == [workspaceID])
        let routing = try #require(recorder.routings.first)
        #expect(routing.workspaceID == workspaceID)
        #expect(routing.hasWindowIDParam == false)
        #expect(routing.windowID == nil)
        #expect(routing.groupID == nil)
        #expect(routing.surfaceID == nil)
        #expect(routing.paneID == nil)
    }
}
