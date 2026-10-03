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
        #expect(CloudTreeResourceName(resource: browser, remoteView: view(name: "Docs")).browserName == "Docs")
        // Without a tab name the page title is all there is, and it is better
        // than the placeholder.
        #expect(CloudTreeResourceName(resource: browser, remoteView: view(name: nil)).browserName == "Example Domain")
        #expect(CloudTreeResourceName(resource: browser, remoteView: nil).browserName == "Example Domain")
    }

    @Test("a browser with no name of any kind still has something to show")
    func untitledBrowserFallsBack() {
        let untitled = resource(kind: .browser, key: "browser-1", title: "")
        #expect(CloudTreeResourceName(resource: untitled, remoteView: nil).browserName == "browser")
        // Whitespace is not a name. A row that renders as blank is worse than
        // one that admits it is unnamed.
        #expect(CloudTreeResourceName(resource: untitled, remoteView: view(name: "   ")).browserName == "browser")
    }

    @Test("displays resolve the same way")
    func displayFollowsTheSameRule() {
        let desktop = resource(kind: .display, key: "screen-1", title: "")
        #expect(CloudTreeResourceName(resource: desktop, remoteView: view(name: "Big screen")).displayName == "Big screen")
        #expect(CloudTreeResourceName(resource: desktop, remoteView: nil).displayName == "Desktop")
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
    /// name (`row.displayTitle`); the display case read `resource.title` raw, so
    /// a renamed desktop dragged out still landed under its bare resource title
    /// and the rename looked undone.
    @Test("a dragged display carries the name the row is showing")
    func dragGroupCarriesTheRowsName() throws {
        let desktop = resource(kind: .display, key: "screen-1", title: "")
        let renamed = CloudTreeNode(
            id: "screen-1",
            kind: .display(desktop, openIn: nil, remoteView: view(name: "Docs"))
        )
        #expect(try #require(renamed.dragGroup).title == "Docs")

        let unnamed = CloudTreeNode(
            id: "screen-2",
            kind: .display(resource(kind: .display, key: "screen-2", title: ""), openIn: nil, remoteView: view(name: nil))
        )
        // Untitled and unnamed: the drag lands under the same placeholder the
        // row shows instead of an empty title.
        #expect(try #require(unnamed.dragGroup).title == "Desktop")
    }

    /// A browser row has no projection capability, so nothing ever reads its
    /// drag group. This pins the reason `dragGroup` carries no browser branch:
    /// `CloudTreeDragRegistration` is its only leaf-row reader and it requires
    /// `isDragSource` first. Granting browsers the capability is a design change
    /// and would come with its own behavioral test.
    @Test("a browser row does not export a pane projection")
    func browserRowIsNotADragSource() {
        let node = CloudTreeNode(
            id: "browser-1",
            kind: .browser(CloudTreeBrowserRow(
                resource: resource(kind: .browser, key: "browser-1", title: "Example Domain"),
                isOpen: false,
                workspaceTitle: nil,
                remoteView: view(name: "Docs")
            ))
        )
        #expect(!node.isDragSource)
    }

    /// A rename writes to a daemon tab, so a row with no tab has nothing to
    /// write to and must not offer the verb. A paired Mac is excluded even with
    /// a tab: its host verb only resolves terminals.
    @Test("rename is offered only where there is a tab to rename")
    func renameNeedsATab() {
        let browser = resource(kind: .browser, key: "browser-1", title: "Example Domain")
        #expect(CloudTreeOutlineView.canRenameRemoteView(resource: browser, remoteView: view(name: nil)))
        #expect(CloudTreeOutlineView.canRenameRemoteView(resource: browser, remoteView: nil) == false)

        let onDevice = SurfaceResource(
            id: SurfaceResourceID(
                machine: .device(SurfaceDeviceInstanceID(deviceID: "22222222-2222-2222-2222-222222222222", tag: "default")),
                kind: .browser,
                key: "surface-9"
            ),
            title: "Example Domain",
            detail: nil,
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            remoteViews: [],
            port: nil,
            url: nil
        )
        #expect(CloudTreeOutlineView.canRenameRemoteView(resource: onDevice, remoteView: view(name: nil)) == false)

        let forwardedPort = resource(
            kind: .browser,
            key: SurfaceResourceID.portKey(8080),
            title: "Example Domain"
        )
        #expect(CloudTreeOutlineView.canRenameRemoteView(resource: forwardedPort, remoteView: view(name: nil)) == false)
    }

    /// The prompt and the drag payload hold a resource, not a row, so they
    /// cannot reach the row's switch. They ask by kind instead, and must get
    /// the same answer the row rendered.
    @Test("a reader with only a resource gets the row's own name")
    func labelFollowsTheRowByKind() {
        let untitledBrowser = resource(kind: .browser, key: "browser-1", title: "")
        #expect(CloudTreeResourceName(resource: untitledBrowser, remoteView: nil).label == "browser")
        let untitledDisplay = resource(kind: .display, key: "screen-1", title: "")
        #expect(CloudTreeResourceName(resource: untitledDisplay, remoteView: nil).label == "Desktop")
        #expect(CloudTreeResourceName(resource: untitledBrowser, remoteView: view(name: "Docs")).label == "Docs")
    }
}
