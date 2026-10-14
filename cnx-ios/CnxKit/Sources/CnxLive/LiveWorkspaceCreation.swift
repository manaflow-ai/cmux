import CnxModel
import Foundation

/// Creates workspaces on the linked Mac's cmux-tui daemon. The phone's
/// `daemon` lane (cnx-hostd policy) allows `new-workspace {name}` and
/// `new-browser-tab`, but never a working directory (`cwd`) or a
/// conversation tab, so the long-press menu offers only the browser start:
/// no recent directories, no agent first tab, no git clone.
@MainActor
public final class LiveWorkspaceCreationBackend: WorkspaceCreationBackend {
    private let sync: WorkspaceSync
    private let link: LinkController

    public init(sync: WorkspaceSync, link: LinkController) {
        self.sync = sync
        self.link = link
    }

    public func canCreate(on macID: String) -> Bool {
        link.target?.macID == macID && link.phase.isConnected && sync.daemon != nil && sync.macID == macID
    }

    public func options(on macID: String) -> WorkspaceCreationOptions {
        WorkspaceCreationOptions(directories: false, agents: [], browser: true, cloneFromGit: false)
    }

    public func create(_ request: NewWorkspaceRequest, placeholder: Workspace) async throws -> Workspace {
        guard canCreate(on: request.macID), let client = sync.daemon else {
            throw WorkspaceCreationError("Not connected")
        }
        do {
            // One screen, one pane, one terminal at the daemon's default
            // directory; the new workspace becomes the active one.
            let reply = try WorkspaceSync.check(await client.request("new-workspace", params: ["name": placeholder.title]))
            guard let surface = (reply["data"] as? [String: Any])?["surface"] as? Int else {
                throw WorkspaceCreationError("The Mac didn't say which workspace it created")
            }
            var opening = DaemonTree.tabID(surface: surface)
            if request.start == .browser {
                // No pane: the active pane, which is the new workspace's. If
                // the Mac has no browser runtime the workspace still stands,
                // and opens on its terminal.
                if let browser = try? WorkspaceSync.check(await client.request("new-browser-tab", params: ["url": "about:blank"])),
                   let id = (browser["data"] as? [String: Any])?["surface"] as? Int {
                    opening = DaemonTree.tabID(surface: id)
                }
            }
            let tree = try await sync.listNow()
            guard let created = tree.workspaces.first(where: { $0.tabs.contains { $0.id == opening } })
                ?? tree.workspaces.first(where: { $0.tabs.contains { $0.id == DaemonTree.tabID(surface: surface) } }) else {
                throw WorkspaceCreationError("The new workspace didn't appear on the Mac")
            }
            return created
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }
}
