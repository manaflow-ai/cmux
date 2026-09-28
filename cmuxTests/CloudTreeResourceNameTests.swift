import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Display and browser rows each have two candidate names: the daemon tab's,
/// which someone typed, and the resource's own, which is generated and moves on
/// its own (a browser's is the page title). These pin which one wins and what
/// is shown when neither exists.
@Suite("Cloud tree resource names")
struct CloudTreeResourceNameTests {
    private let machine = SurfaceMachineID.cloud("freestyle-vm")
    private let workspace = SurfaceRemoteWorkspace(id: "ws-1", name: "main", index: 0, focused: true)

    private func resource(kind: SurfaceResourceKind, key: String, title: String) -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: kind, key: key),
            title: title,
            detail: nil,
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            remoteViews: [],
            port: nil,
            url: nil
        )
    }

    private func view(name: String?) -> SurfaceRemoteView {
        SurfaceRemoteView(tabID: "tab-1", workspace: workspace, name: name)
    }

    @Test("a typed name outranks a page title that moves on its own")
    func chosenNameBeatsGeneratedTitle() {
        let browser = resource(kind: .browser, key: "browser-1", title: "Example Domain")
        #expect(CloudTreeResourceName.browser(resource: browser, remoteView: view(name: "Docs")) == "Docs")
        // Without a tab name the page title is all there is, and it is better
        // than the placeholder.
        #expect(CloudTreeResourceName.browser(resource: browser, remoteView: view(name: nil)) == "Example Domain")
        #expect(CloudTreeResourceName.browser(resource: browser, remoteView: nil) == "Example Domain")
    }

    @Test("a browser with no name of any kind still has something to show")
    func untitledBrowserFallsBack() {
        let untitled = resource(kind: .browser, key: "browser-1", title: "")
        #expect(CloudTreeResourceName.browser(resource: untitled, remoteView: nil) == "browser")
        // Whitespace is not a name. A row that renders as blank is worse than
        // one that admits it is unnamed.
        #expect(CloudTreeResourceName.browser(resource: untitled, remoteView: view(name: "   ")) == "browser")
    }

    @Test("displays resolve the same way")
    func displayFollowsTheSameRule() {
        let desktop = resource(kind: .display, key: "screen-1", title: "")
        #expect(CloudTreeResourceName.display(resource: desktop, remoteView: view(name: "Big screen")) == "Big screen")
        #expect(CloudTreeResourceName.display(resource: desktop, remoteView: nil) == "Desktop")
    }

    /// Typing a browser's name has to find it. Before this the browser case
    /// returned `resource.title` raw, so an untitled browser's searchable
    /// title was the empty string and no query reached it, while machines,
    /// workspaces and terminals all fell back to something typeable.
    @Test("an untitled browser is reachable by typing")
    func untitledBrowserIsSearchable() {
        let untitled = resource(kind: .browser, key: "browser-1", title: "")
        let node = CloudTreeNode(
            id: "browser-1",
            kind: .browser(CloudTreeBrowserRow(resource: untitled, isOpen: false, workspaceTitle: nil))
        )
        #expect(node.searchableTitle == "browser")

        let named = CloudTreeNode(
            id: "browser-2",
            kind: .browser(CloudTreeBrowserRow(
                resource: untitled,
                isOpen: false,
                workspaceTitle: nil,
                remoteView: view(name: "Docs")
            ))
        )
        #expect(named.searchableTitle == "Docs")
    }

    /// Dragging a row out builds a group whose title names the local workspace
    /// that comes out the other end. The terminal case already reads the tab
    /// name (`row.displayTitle`); the browser and display cases read
    /// `resource.title` raw, so a renamed browser dragged out still lands under
    /// its page title and the rename looks undone.
    @Test("a dragged row carries the name the row is showing")
    func dragGroupCarriesTheRowsName() throws {
        let browser = resource(kind: .browser, key: "browser-1", title: "Example Domain")
        let node = CloudTreeNode(
            id: "browser-1",
            kind: .browser(CloudTreeBrowserRow(
                resource: browser,
                isOpen: false,
                workspaceTitle: nil,
                remoteView: view(name: "Docs")
            ))
        )
        let group = try #require(node.dragGroup)
        #expect(group.title == "Docs")

        let desktop = resource(kind: .display, key: "screen-1", title: "")
        let displayNode = CloudTreeNode(
            id: "screen-1",
            kind: .display(desktop, openIn: nil, remoteView: view(name: nil))
        )
        // Untitled and unnamed: the drag lands under the same placeholder the
        // row shows instead of an empty title.
        let displayGroup = try #require(displayNode.dragGroup)
        #expect(displayGroup.title == "Desktop")
    }

    /// A rename writes to a daemon tab, so a row with no tab has nothing to
    /// write to and must not offer the verb.
    @Test("rename is offered only where there is a tab to rename")
    func renameNeedsATab() {
        #expect(CloudTreeOutlineView.canRenameRemoteView(remoteView: view(name: nil)))
        #expect(CloudTreeOutlineView.canRenameRemoteView(remoteView: nil) == false)
    }
}
