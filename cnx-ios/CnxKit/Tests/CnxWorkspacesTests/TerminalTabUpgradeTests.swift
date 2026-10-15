import Foundation
import Testing
@testable import CnxWorkspaces

/// design/terminal R1-0: a terminal page built before live data (a launch
/// restore) moves to its live session once the tree lists its surface.
@Suite struct TerminalTabUpgradeTests {
    @Test func restoredPlaceholderIsOfferedItsLiveSession() {
        var upgrade = TerminalTabUpgrade()
        // Cold launch: the restore opens the workspace before the tree exists.
        upgrade.built(tabID: "t1", workspaceID: "w1", live: false)
        var tree: Set<String> = []
        #expect(upgrade.upgradable { tree.contains($0) }.isEmpty)
        // The link comes up and the tree lists the tab's surface.
        tree = ["t1"]
        #expect(upgrade.upgradable { tree.contains($0) } == ["t1"])
        // Upgraded: the live host is built; nothing is offered again.
        upgrade.built(tabID: "t1", workspaceID: "w1", live: true)
        #expect(upgrade.upgradable { tree.contains($0) }.isEmpty)
    }

    @Test func liveTabsAndClosedTabsAreNotOffered() {
        var upgrade = TerminalTabUpgrade()
        upgrade.built(tabID: "a", workspaceID: "w", live: true)
        upgrade.built(tabID: "b", workspaceID: "w", live: false)
        upgrade.built(tabID: "c", workspaceID: "w", live: false)
        upgrade.removed(tabID: "c")
        #expect(upgrade.upgradable { _ in true } == ["b"])
        upgrade.reset()
        #expect(upgrade.upgradable { _ in true }.isEmpty)
    }

    @Test func lastFramesSurviveARelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("frames-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TerminalFrameStore(directory: dir)
        store.save(Data([1, 2, 3]), for: "s/12:tab")
        // A new store (a new launch) reads it back; the id is a safe file name.
        #expect(TerminalFrameStore(directory: dir).load("s/12:tab") == Data([1, 2, 3]))
        #expect(store.url(for: "s/12:tab").lastPathComponent == "s_12_tab.jpg")
        store.remove("s/12:tab")
        #expect(store.load("s/12:tab") == nil)
    }

    /// Round 11 A5: a frame rendered off the main thread and written late
    /// must not replace a newer frame, nor bring back a closed tab's file.
    @Test func aLateFrameNeverReplacesANewerOneOrAClosedTab() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("frames-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TerminalFrameStore(directory: dir)
        let old = store.ticket(for: "t")
        store.save(Data([2]), for: "t")  // a newer frame, written at once (going to the background)
        store.save(Data([1]), for: "t", ticket: old)
        #expect(store.load("t") == Data([2]))
        let late = store.ticket(for: "t")
        store.remove("t")  // the tab closed
        store.save(Data([3]), for: "t", ticket: late)
        #expect(store.load("t") == nil)
        let next = store.ticket(for: "t")
        store.save(Data([4]), for: "t", ticket: next)
        #expect(store.load("t") == Data([4]))
    }
}
