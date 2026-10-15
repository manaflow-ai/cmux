import Foundation
import Testing
@testable import CnxLive

/// The Mac's home workspace (`kind: "home"`, `workspace-kind-v1`) is what the
/// Mac sidebar's Home item shows, not a workspace row (`SidebarMapping`
/// filters `homeKind`). The phone has its own Home tab, so the home workspace
/// never becomes a Workspaces row, a search result or a count. The filter is
/// the kind, never the name: a renamed home stays out, a workspace the user
/// named "Home" stays in.
@Suite struct HomeWorkspaceTests {
    static let reply = Data("""
    {"ok":true,"data":{"workspace_revision":9,"workspaces":[
      {"id":1,"key":"ws-home","name":"Home","kind":"home","active":false,"unread_count":3,"screens":[
        {"id":1,"active":true,"active_pane":1,"panes":[{"id":1,"active_tab":0,"tabs":[
          {"surface":11,"kind":"pty","title":"zsh","cwd":"/Users/me","notification":{"notification":4,"unread":true}}
        ]}]}
      ]},
      {"id":2,"key":"ws-1","name":"workspace-1","kind":"normal","screens":[
        {"id":2,"active":true,"active_pane":2,"panes":[{"id":2,"active_tab":0,"tabs":[
          {"surface":12,"kind":"pty","title":"zsh","cwd":"/Users/me/src"}
        ]}]}
      ]},
      {"id":3,"key":"ws-named-home","name":"Home","title":"Home","screens":[]},
      {"id":4,"key":"ws-renamed-home","name":"Inbox","title":"Inbox","kind":"home","screens":[]}
    ]}}
    """.utf8)

    @Test func homeKindIsNotAWorkspace() throws {
        let tree = try DaemonTree(reply: Self.reply, macID: "mac")
        #expect(tree.workspaces.map(\.id) == ["ws-1", "ws-named-home"])
        // Nothing of the home workspace leaks through the tree's other maps either.
        #expect(tree.surfaces["s11"] == nil)
        #expect(tree.notificationMarkers[11] == nil)
        #expect(tree.panes["ws-home"] == nil)
        #expect(tree.directories["s11"] == nil)
    }

    @Test func olderDaemonsWithoutKindKeepEveryWorkspace() throws {
        let reply = Data("""
        {"ok":true,"data":{"workspaces":[{"id":1,"key":"a","name":"Home","screens":[]},{"id":2,"key":"b","name":"b","screens":[]}]}}
        """.utf8)
        #expect(try DaemonTree(reply: reply, macID: "mac").workspaces.map(\.id) == ["a", "b"])
    }
}
