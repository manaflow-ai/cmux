import AppKit
import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cmux tree --all` stops listing a workspace once it is closed, even when it was
/// not the selected one (https://github.com/manaflow-ai/cmux/issues/22221).
///
/// The socket answers topology reads such as `system.tree` from a published read
/// snapshot, and caches a read it had to compute, keyed by its exact params, until
/// the next snapshot is published. Closing a workspace that is not selected
/// published nothing, so `tree --all` (`{"all_windows": true}`) kept returning the
/// closed workspace while `tree --window` and `list-workspaces` did not.
@Suite(.serialized)
struct SocketTreeAllAfterWorkspaceCloseTests {
    @Test @MainActor
    func treeAllDropsAClosedBackgroundWorkspace() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow(shouldActivate: false)
            defer { appDelegate.discardMainWindowWithoutClosedHistory(windowId: windowId) }
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))

            let selectedId = try #require(manager.selectedTabId)
            let selected = try #require(manager.tabs.first { $0.id == selectedId })
            let probe = manager.addWorkspace(title: "probe", select: false, autoWelcomeIfNeeded: false)
            try #require(manager.selectedTabId == selected.id, "the probe workspace must stay in the background")

            // Let any refresh already scheduled publish first, so the read below is
            // the one that gets cached, as a client's next poll is.
            try await Self.settleSnapshotRefresh()
            let before = try await Self.treeAll()
            try #require(before.contains(probe.id.uuidString), "tree --all should list the new workspace: \(before)")
            let store = TerminalController.shared.socketReadSnapshotStore
            try #require(
                store.response(method: "system.tree", params: ["all_windows": .bool(true)]) != nil,
                "tree --all should now be served from the read snapshot"
            )

            // The sidebar's close of a workspace that is not selected.
            manager.closeWorkspace(probe)
            #expect(!manager.tabs.contains { $0.id == probe.id })
            // A refresh the close scheduled publishes on a later main-actor turn.
            try await Self.settleSnapshotRefresh()

            let after = try await Self.treeAll()
            #expect(!after.contains(probe.id.uuidString), "tree --all still lists the closed workspace: \(after)")
            #expect(after.contains(selected.id.uuidString), "tree --all lost the open workspace: \(after)")
        }
    }

    /// Waits for a scheduled read-snapshot refresh, if there is one, to publish.
    @MainActor
    private static func settleSnapshotRefresh() async throws {
        for _ in 0..<10 {
            guard let refresh = TerminalController.shared.socketReadSnapshotRefreshTask else { return }
            await refresh.value
        }
    }

    /// `cmux tree --all`, sent the way a socket client sends it, so the answer
    /// comes from the same read-snapshot path a client gets.
    private static func treeAll() async throws -> String {
        let line = #"{"id":"tree","method":"system.tree","params":{"all_windows":true}}"#
        let controller = TerminalController.shared
        let response = await Task.detached {
            await controller.processCommandUsingSocketExecutionPolicyAsync(line)
        }.value
        let text = try #require(response)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        try #require(envelope["ok"] as? Bool == true, "system.tree failed: \(text)")
        return text
    }
}
