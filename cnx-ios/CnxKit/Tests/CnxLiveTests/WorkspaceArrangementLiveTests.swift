import CnxModel
import Foundation
import Testing
@testable import CnxLive

/// Parity round 2 on the live side: what the daemon tree says about pins,
/// colors and order, and the words a phone shows.
@Suite struct WorkspaceArrangementLiveTests {
    static let reply = Data(#"""
    {"ok":true,"data":{"registry_id":"reg_1","workspace_revision":4,"workspaces":[
      {"key":"k-a","title":"alpha","resource_id":"ws_a","color":"blue","pinned":false,"screens":[]},
      {"key":"k-b","title":"beta","resource_id":"ws_b","color":"#ff8800cc","pinned":true,"screens":[]},
      {"key":"k-c","title":"gamma","resource_id":"ws_c","color":"chartreuse","screens":[]}
    ]}}
    """#.utf8)

    @Test func treeCarriesPinsColorsAndIds() throws {
        let tree = try DaemonTree(reply: Self.reply, macID: "m")
        #expect(tree.registryID == "reg_1")
        #expect(tree.legacyPinned == ["k-b"])
        #expect(tree.workspaces.map(\.resourceID) == ["ws_a", "ws_b", "ws_c"])
        // A palette name, a hex color (alpha dropped), and an unknown name (none).
        #expect(tree.workspaces.map(\.colorHex) == ["blue", "#ff8800", nil])
        #expect(tree.workspaces.map(\.isPinned) == [false, true, false])
    }

    @Test func arrangementOrdersAndPinsTheTree() throws {
        var tree = try DaemonTree(reply: Self.reply, macID: "m")
        tree.apply(SidebarArrangement(rows: [.init(session: "reg_1", key: "k-c", index: 0), .init(session: "reg_1", key: "k-a", index: 1)],
                                      pins: [.init(itemID: "itm_aaaaaaaaaaaaaaaa", value: "reg_1:ws_a")]))
        #expect(tree.workspaces.map(\.sidebarIndex) == [1, 2 + 1, 0])
        #expect(tree.workspaces.map(\.isPinned) == [true, true, false])
        #expect(tree.workspaces[0].pinItemID == "itm_aaaaaaaaaaaaaaaa")
        // No arrangement (an older Mac): the daemon's order.
        var plain = try DaemonTree(reply: Self.reply, macID: "m")
        plain.apply(nil)
        #expect(plain.workspaces.map(\.sidebarIndex) == [0, 1, 2])
    }

    @Test func personalChangesRelistTheTree() {
        #expect(DaemonEvent.parse(Data(#"{"event":"personal-changed"}"#.utf8)) == .treeChanged)
    }

    /// Mark Workspace as Read acknowledges the tabs the Mac shows unread, else all of them.
    @Test func readMarksAcknowledgeUnreadTabs() throws {
        let line = Data(#"""
        {"ok":true,"data":{"workspaces":[{"key":"k","title":"w","screens":[{"active":true,"active_pane":1,"panes":[{"id":1,"active_tab":0,"tabs":[
          {"surface":5,"kind":"pty","notification":{"notification":9,"unread":true}},
          {"surface":6,"kind":"pty"}]}]}]}]}}
        """#.utf8)
        let tree = try DaemonTree(reply: line, macID: "m")
        var ws = try #require(tree.workspaces.first)
        #expect(LiveWorkspaceCreationBackend.unreadSurfaces(of: ws, in: tree) == [5])
        let quiet = try DaemonTree(reply: Data(String(decoding: line, as: UTF8.self).replacingOccurrences(of: "\"unread\":true", with: "\"unread\":false").utf8), macID: "m")
        ws.hasUnread = true
        #expect(LiveWorkspaceCreationBackend.unreadSurfaces(of: ws, in: quiet) == [5, 6])
        ws.hasUnread = false
        #expect(LiveWorkspaceCreationBackend.unreadSurfaces(of: ws, in: quiet).isEmpty)
    }

    /// The trust question stays on the Mac: the phone says what to do, step by step.
    @Test func trustStepsSayWhatToDo() {
        let text = LiveWorkspaceCreationBackend.trustSteps(folder: "proj")
        #expect(text.hasPrefix("Claude hasn't been trusted in proj yet."))
        #expect(text.contains("1. On the Mac, open this workspace in cmux and choose Trust when it asks."))
        #expect(text.contains("2. Here, open this workspace's terminal, type claude, press Return"))
        #expect(text.hasSuffix("Then start the chat again."))
    }

    /// Open Folder… types `cd` with the same rules as Recent Directories.
    @Test func openFolderSharesTheTypedCdRules() {
        #expect(LiveWorkspaceCreationBackend.changeDirectoryLine("~/code/app") == "cd ~/'code/app' && clear\n")
        #expect(LiveWorkspaceCreationBackend.changeDirectoryLine("/tmp/bang!") == nil)
        #expect(!WorkspaceFolderPath.isTypable("/tmp/bang!"))
    }
}
