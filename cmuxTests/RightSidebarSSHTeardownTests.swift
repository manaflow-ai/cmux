import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/5685:
/// after an `ssh` session ends in a local terminal, the right-sidebar Files
/// panel must revert from the remote host back to the local workspace.
///
/// The bug was a missing *trigger*, not a wrong decision. During a
/// local-terminal SSH session `currentDirectory` never changes (Ghostty rejects
/// remote OSC 7 pwd reports), so the only signal that the session started or
/// ended is the terminal title. `RightSidebarToolPanel.observeWorkspaceRootChanges`
/// originally watched only `currentDirectory` / `remote*`, so when the user
/// pressed `Ctrl+D` nothing re-synced and the panel stayed stuck on the remote
/// host. The fix adds `workspace.$title` to the observed publishers.
///
/// This test drives the exact repro: it puts the panel's store into a stale
/// remote state, then changes ONLY the title (leaving `currentDirectory`
/// untouched) and asserts the panel reverts to the local root. Without the
/// `$title` observation the title change fires no re-sync and the store stays on
/// the SSH provider, so this test fails — i.e. it genuinely catches the bug.
@MainActor
@Suite("Files panel reverts to local when an SSH session ends")
struct RightSidebarSSHTeardownTests {
    @Test("Terminal title reset reverts the Files panel from remote to local")
    func titleResetRevertsRemoteToLocal() async throws {
        let localDir = "/private/tmp"

        let workspace = Workspace()
        workspace.currentDirectory = localDir

        let panel = RightSidebarToolPanel(workspace: workspace, mode: .files)
        // Lazily create the store; its initial sync roots at the local cwd because
        // there is no focused terminal panel (so no SSH session is detected).
        let store = panel.fileExplorerStore

        // Precondition: force the store into the "stuck on remote" state that an
        // earlier SSH detection would have produced. A stub transport keeps this
        // off the network.
        store.applyWorkspaceRoot(
            .remoteSSH(
                workspaceId: workspace.id,
                connection: SSHFileExplorerConnection(
                    destination: "dev@remote-host",
                    port: nil,
                    identityFile: nil,
                    sshOptions: []
                ),
                displayTarget: "dev@remote-host",
                rootPath: "/home/dev",
                isAvailable: true,
                unavailableDetail: nil
            ),
            sshTransport: StubSSHFileExplorerTransport()
        )
        try await waitUntil("store is on the SSH provider") {
            store.provider is SSHFileExplorerProvider
        }

        // The SSH session ends. `currentDirectory` is unchanged; only the live
        // terminal title resets (here, to the local shell's prompt).
        workspace.title = "alice@localhost:~"

        // The Files panel must revert to the local workspace root.
        try await waitUntil("Files panel reverts to the local root") {
            store.provider is LocalFileExplorerProvider && store.rootPath == localDir
        }
    }

    /// Polls `condition` on the main actor until it holds or the timeout elapses,
    /// giving the panel's async title-observation sink time to run.
    private func waitUntil(
        _ description: String,
        timeout: Double = 2.0,
        _ condition: () -> Bool
    ) async throws {
        let stepNanos: UInt64 = 20_000_000 // 20ms
        let maxSteps = Int(timeout / 0.02)
        for _ in 0..<maxSteps {
            if condition() { return }
            try await Task.sleep(nanoseconds: stepNanos)
        }
        #expect(condition(), "Timed out waiting for: \(description)")
    }
}

private final class StubSSHFileExplorerTransport: SSHFileExplorerTransport {
    func resolveHomePath(connection: SSHFileExplorerConnection) async throws -> String {
        "/home/dev"
    }

    func listDirectory(
        path: String,
        connection: SSHFileExplorerConnection,
        showHidden: Bool
    ) async throws -> [FileExplorerEntry] {
        []
    }

    func downloadFile(
        path: String,
        connection: SSHFileExplorerConnection,
        to localURL: URL
    ) async throws {}
}
